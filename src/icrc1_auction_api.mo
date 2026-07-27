import Array "mo:core/Array";
import Error "mo:core/Error";
import Float "mo:core/Float";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Option "mo:core/Option";
import Prim "mo:prim";
import Principal "mo:core/Principal";
import R "mo:core/Result";
import Text "mo:core/Text";
import Timer "mo:core/Timer";
import Map "mo:core/Map";
import VarArray "mo:core/VarArray";

import Queue "mo:core/Queue";
import PureList "mo:core/pure/List";

import ICRC84 "mo:icrc-84";
import PT "mo:promtracker";
import { Counter; Gauge } "mo:promtracker";
import PtHttp "mo:promtracker/mixins/http";
import TokenHandler "mo:token-handler";

import AssetsStorage "./auction/src/assets_storage";
import Auction "./auction/src";
import AuctionRuntime "./auction/src/runtime";
import UsersStorage "./auction/src/users_storage";
import E "./auction/src/encryption";
import ICRC84Auction "./icrc84_auction";

import AdminsMixin "./mixins/admins_mixin";
import BtcHandler "./btc_handler";
import FloatUtils "./utils/float";
import NotificationDelegate "./notification_delegate";
import Scheduler "./utils/scheduler";
import TextUtils "./utils/text";
import U "./utils";

// arguments have to be provided on first canister install,
// on upgrade quote ledger will be ignored
persistent actor class Icrc1AuctionAPI(quoteLedger_ : ?Principal, adminPrincipal_ : ?Principal, cryptoCanisterId : ?Principal) = self {

  include AdminsMixin(adminPrincipal_);

  // ensure compliance to ICRC84 standart.
  // actor won't compile in case of type mismatch here
  transient let _ : ICRC84.ICRC84 = self;

  // constants
  transient let AUCTION_INTERVAL_SECONDS : Nat64 = 1800;

  // Bitcoin mainnet
  transient let CKBTC_LEDGER_PRINCIPAL = Principal.fromText("mxzaz-hqaaa-aaaar-qaada-cai");
  transient let CKBTC_MINTER = {
    principal = Principal.fromText("mqygn-kiaaa-aaaar-qaadq-cai");
    xPubKey = {
      public_key : Blob = "\02\22\04\7A\81\D4\F8\A0\67\03\1C\89\27\3D\24\1B\79\A5\A0\07\C0\4D\FA\F3\6D\07\96\3D\B0\B9\90\97\EB";
      chain_code : Blob = "\82\1A\EB\B6\43\BD\97\D3\19\D2\FD\0B\2E\48\3D\4E\7D\E2\EA\90\39\FF\67\56\8B\69\3E\6A\BC\14\A0\3B";
    };
  };
  // Bitcoin testnet
  // let CKBTC_LEDGER_PRINCIPAL = Principal.fromText("mc6ru-gyaaa-aaaar-qaaaq-cai");
  // let CKBTC_MINTER = {
  //   principal = Principal.fromText("ml52i-qqaaa-aaaar-qaaba-cai");
  //   xPubKey = // load with "await* CkBtcAddress.fetchEcdsaKey(Principal.fromText("ml52i-qqaaa-aaaar-qaaba-cai"));"
  // };

  transient let TCYCLES_LEDGER_PRINCIPAL = Principal.fromText("um5iw-rqaaa-aaaaq-qaaba-cai");
  transient let tcyclesLedger : (
    actor {
      withdraw : shared ({
        to : Principal;
        from_subaccount : ?[Nat8];
        created_at_time : ?Nat64;
        amount : Nat;
      }) -> async ({
        #Ok : Nat;
        #Err : CyclesLedgerWithdrawError;
      });
    }
  ) = actor (Principal.toText(TCYCLES_LEDGER_PRINCIPAL));

  type AssetInfo = {
    ledgerPrincipal : Principal;
    minAskVolume : Nat;
    handler : TokenHandler.TokenHandler;
    symbol : Text;
    decimals : Nat;
  };

  type RegisterAssetError = {
    #AlreadyRegistered;
  };

  type Order = {
    icrc1Ledger : Principal;
    orderBookType : Auction.OrderBookType;
    price : Float;
    volume : Nat;
  };
  func mapOrder(order : Auction.Order) : Order = ({
    order with
    icrc1Ledger = assets.at(order.assetId).ledgerPrincipal;
    volume = order.volume;
  });

  type UserOrder = {
    user : Principal;
    price : Float;
    volume : Nat;
  };
  func mapUserOrder(order : Auction.Order) : UserOrder = ({
    user = order.userPrincipal;
    price = order.price;
    volume = order.volume;
  });

  type UpperResult<Ok, Err> = { #Ok : Ok; #Err : Err };

  type AuctionQuerySelection = {
    session_numbers : ?Bool;
    asks : ?Bool;
    bids : ?Bool;
    dark_order_books : ?Bool;
    credits : ?Bool;
    deposit_history : ?(limit : Nat, skip : Nat);
    transaction_history : ?(limit : Nat, skip : Nat);
    price_history : ?(limit : Nat, skip : Nat, skipEmpty : Bool);
    immediate_price_history : ?(limit : Nat, skip : Nat);
    last_prices : ?Bool;
    last_immediate_prices : ?Bool;
    order_book_info : ?Bool;
    immediate_order_book_info : ?Bool;
    reversed_history : ?Bool;
  };

  type AuctionQueryResponse = {
    session_numbers : [(Principal, Nat)];
    asks : [(Auction.OrderId, Order)];
    bids : [(Auction.OrderId, Order)];
    dark_order_books : [(Principal, Auction.EncryptedOrderBook)];
    credits : [(Principal, Auction.CreditInfo)];
    deposit_history : [DepositHistoryItem];
    transaction_history : [TransactionHistoryItem];
    price_history : [PriceHistoryItem];
    immediate_price_history : [PriceHistoryItem];
    last_prices : [PriceHistoryItem];
    last_immediate_prices : [PriceHistoryItem];
    order_book_info : [(Principal, Auction.OrderBookInfo)];
    immediate_order_book_info : [(Principal, Auction.ImmediateOrderBookInfo)];
    points : Nat;
    account_revision : Nat;
  };

  type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, ledgerPrincipal : Principal, volume : Nat, price : Float);
  type DepositHistoryItem = (timestamp : Nat64, kind : { #deposit; #withdrawal }, ledgerPrincipal : Principal, volume : Nat);
  type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, ledgerPrincipal : Principal, volume : Nat, price : Float);

  type BtcNotifyResult = {
    #Ok : {
      deposit_inc : Nat;
      credit_inc : Nat;
      credit : Int;
    };
    #Err : {
      #CallLedgerError : { message : Text };
      #NotAvailable : { message : Text };
    } or BtcHandler.NotifyError;
  };

  type BtcWithdrawResult = {
    #Ok : { block_index : Nat64 };
    #Err : {
      #InsufficientCredit : {};
    } or BtcHandler.ApproveError or BtcHandler.RetrieveBtcWithApprovalError;
  };

  type CyclesLedgerWithdrawError = {
    #FailedToWithdraw : {
      rejection_code : {
        #NoError;
        #CanisterError;
        #SysTransient;
        #DestinationInvalid;
        #Unknown;
        #SysFatal;
        #CanisterReject;
      };
      fee_block : ?Nat;
      rejection_reason : Text;
    };
    #GenericError : { error_message : Text; error_code : Nat64 };
    #TemporarilyUnavailable;
    #Duplicate : { duplicate_of : Nat };
    #BadFee : { expected_fee : Nat };
    #InvalidReceiver : { receiver : Principal };
    #CreatedInFuture : { ledger_time : Nat64 };
    #TooOld;
    #InsufficientFunds : { balance : Nat };
  };

  type DirectCyclesWithdrawResult = {
    #Ok : {
      txid : Nat;
      amount : Nat;
    };
    #Err : {
      #InsufficientCredit : {};
      #TooLowAmount : {};
    } or CyclesLedgerWithdrawError;
  };

  func getTokenHandlerContext(ledgerPrincipal : Principal) : TokenHandler.TokenHandlerContext {
    {
      api = TokenHandler.buildLedgerApi(ledgerPrincipal);
      ownPrincipal = Principal.fromActor(self);
      assertInvariant = func() = true;
      onFeeChanged = func(oldFee, newFee) {};
      log = func(p : Principal, logEvent : TokenHandler.LogEvent) = tokenHandlersJournal.add((ledgerPrincipal, p, logEvent));
    };
  };

  let tokenHandlersJournal : List.List<(ledger : Principal, p : Principal, logEvent : TokenHandler.LogEvent)> = List.empty();
  var consolidationTimerEnabled : Bool = true;
  let assets : List.List<AssetInfo> = List.empty();
  let auction : Auction.Auction = Auction.new(
    0,
    {
      volumeStepLog10 = 3; // minimum quote volume step 1_000
      minVolumeSteps = 5; // minimum quote volume is 5_000
      priceMaxDigits = 5;
    },
  );
  transient let auctionRuntime : AuctionRuntime.AuctionRuntime = AuctionRuntime.AuctionRuntime(
    auction,
    {
      minAskVolume = func(assetId, _) = assets.at(assetId).minAskVolume;
      performanceCounter = Prim.performanceCounter;
    },
  );

  // will be set in startAuctionTimer_
  // this timestamp is set right before starting auction execution
  transient var nextAuctionTickTimestamp = 0;
  // this timestamp is set after auction session executed completely, sycnhronized with auction.sessionsCounter
  transient var nextSessionTimestamp = 0;

  private func registerAsset_(ledgerPrincipal : Principal, minAskVolume : Nat) : async* R.Result<Nat, RegisterAssetError> {
    let id = assets.size();
    assert id == auction.assets.nAssets();
    if (id == 0) {
      let quoteLedgerPrincipal = U.requireMsg(quoteLedger_, "Quote ledger principal not provided");
      if (ledgerPrincipal != quoteLedgerPrincipal) {
        Prim.trap("Cannot register another token before registering quote");
      };
    };
    let canister = actor (Principal.toText(ledgerPrincipal)) : (actor { icrc1_decimals : () -> async Nat8; icrc1_symbol : () -> async Text });
    let decimalsCall = canister.icrc1_decimals();
    let symbolCall = canister.icrc1_symbol();
    let decimals = Nat8.toNat(await decimalsCall);
    let symbol = await symbolCall;

    if (assets.any<AssetInfo>(func(a) = Principal.equal(ledgerPrincipal, a.ledgerPrincipal))) {
      return #err(#AlreadyRegistered);
    };
    assets.add({
      ledgerPrincipal;
      minAskVolume;
      handler = TokenHandler.new({
        ownPrincipal = Principal.fromActor(self);
        initialFee = 0;
        triggerOnNotifications = true;
      });
      symbol;
      decimals;
    });
    auction.registerAssets(1);
    registerAssetMetrics_(id);
    #ok(id);
  };

  let pt = PT.Tracker.new();
  transient let renderer = PT.Renderer();
  renderer.addCanisterLabel(self);
  include PtHttp(renderer.renderExposition, "/metrics");
  PT.Tracker.setHoldDown(pt, 62);

  renderer.addValue(PT.allSystemMetrics);
  transient let sessionStartTimeBaseOffsetMetric = PT.Tracker.newCounter(pt, "session_start_time_base_offset", []);
  transient let sessionStartTimeGauge = PT.Tracker.newGauge(pt, "session_start_time_offset_ms", [], [0, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 64_000, 128_000]);

  transient let startupTime = Prim.time();
  renderer.addValue(
    PT.bundle(
      [
        PT.newValue("uptime", [], func() = Nat64.toNat((Prim.time() - startupTime) / 1_000_000_000)),
        PT.newValue("sessions_counter", [], func() = auction.sessionsCounter),
        PT.newValue("assets_count", [], func() = auction.assets.nAssets()),
        PT.newValue("users_count", [], func() = auction.users.nUsers()),
        PT.newValue("users_with_credits_count", [], func() = auction.users.nUsersWithCredits()),
        PT.newValue("accounts_count", [], func() = auction.users.nAccounts()),
        PT.newValue("quote_surplus", [], func() = auction.users.quoteSurplus),
        PT.newValue("next_session_timestamp", [], func() = nextAuctionTickTimestamp),
        PT.newValue("total_unique_participants", [], func() = auction.users.participantsArchiveSize),
        PT.newValue("active_unique_participants", [], func() = auction.users.nUsersWithActiveOrders()),
        PT.newValue(
          "monthly_active_participants_count",
          [],
          func() {
            let ts : Nat64 = Prim.time() - 30 * 24 * 60 * 60_000_000_000;
            var amount : Nat = 0;
            for ((_, { lastOrderPlacement }) in auction.users.participantsArchive.entries()) {
              if (lastOrderPlacement > ts) {
                amount += 1;
              };
            };
            amount;
          },
        ),
        PT.newValue("total_orders", [], func() = auction.ordersCounter),
        PT.newValue("auctions_run_count", [], func() = auction.assets.historyLength(#delayed)),
        PT.newValue("trading_pairs_count", [], func() = auction.assets.nAssets() - 1),
      ],
      [],
    )
  );

  // call stats
  let notifyCounter = PT.Tracker.newCounter(pt, "total_calls__icrc84_notify", []);
  let depositCounter = PT.Tracker.newCounter(pt, "total_calls__icrc84_deposit", []);
  let withdrawCounter = PT.Tracker.newCounter(pt, "total_calls__icrc84_withdraw", []);
  let manageOrdersCounter = PT.Tracker.newCounter(pt, "total_calls__manageOrders", []);
  let manageDarkOrderBooksCounter = PT.Tracker.newCounter(pt, "total_calls__manageDarkOrderBooks", []);
  let orderPlacementCounter = PT.Tracker.newCounter(pt, "total_calls__order_placement", []);
  let orderReplacementCounter = PT.Tracker.newCounter(pt, "total_calls__order_replacement", []);
  let orderCancellationCounter = PT.Tracker.newCounter(pt, "total_calls__order_cancellation", []);

  private func registerAssetMetrics_(assetId : Auction.AssetId) {
    let tokenHandler = assets.at(assetId).handler;

    if (assetId != auction.quoteAssetId) {
      let asset = auction.assets.getAsset(assetId);

      let priceMultiplier = 10 ** Int.toFloat(assets.at(assetId).decimals);
      let renderPrice = func(price : Float) : Nat = Int.abs(Float.toInt(price * priceMultiplier));

      renderer.addValue(
        PT.bundle(
          [
            PT.bundle(
              [
                PT.newValue("asks_count", [], func() = asset.asks.immediate.size),
                PT.newValue("asks_volume", [], func() = asset.asks.immediate.totalVolume),
                PT.newValue("bids_count", [], func() = asset.bids.immediate.size),
                PT.newValue("bids_volume", [], func() = asset.bids.immediate.totalVolume),
              ],
              [("order_book", "immediate")],
            ),
            PT.bundle(
              [
                PT.newValue("asks_count", [], func() = asset.asks.delayed.size),
                PT.newValue("asks_volume", [], func() = asset.asks.delayed.totalVolume),
                PT.newValue("bids_count", [], func() = asset.bids.delayed.size),
                PT.newValue("bids_volume", [], func() = asset.bids.delayed.totalVolume),
              ],
              [("order_book", "delayed")],
            ),
            PT.newValue("processing_instructions", [], func() = asset.lastProcessingInstructions),
            PT.newValue("total_executed_volume_base", [], func() = asset.totalExecutedVolumeBase),
            PT.newValue("total_executed_volume_quote", [], func() = asset.totalExecutedVolumeQuote),
            PT.newValue("total_executed_orders", [], func() = asset.totalExecutedOrders),
            PT.newValue(
              "clearing_price",
              [],
              func() = auction.orderBookInfo(assetId, auctionRuntime)
              |> (switch (_.clearing) { case (#match x) { x.price }; case (_) { 0.0 } })
              |> renderPrice(_),
            ),
            PT.newValue(
              "clearing_volume",
              [],
              func() = auction.orderBookInfo(assetId, auctionRuntime)
              |> (switch (_.clearing) { case (#match x) { x.volume }; case (_) { 0 } }),
            ),
            PT.newValue(
              "last_price",
              [],
              func() = auction.getPriceHistory([assetId], #desc, false).next()
              |> (
                switch (_) {
                  case (?item) renderPrice(item.4);
                  case (null) 0;
                }
              ),
            ),
            PT.newValue(
              "last_volume",
              [],
              func() = auction.getPriceHistory([assetId], #desc, false).next()
              |> (
                switch (_) {
                  case (?item) item.3;
                  case (null) 0;
                }
              ),
            ),
          ],
          [("asset_id", assets.at(assetId).symbol)],
        )
      );
    };
    renderer.addValue(
      PT.bundle(
        [
          PT.newValue("token_handler_locks", [], func() = TokenHandler.state(tokenHandler).users.locked),
          PT.newValue("token_handler_frozen", [], func() = if (TokenHandler.isFrozen(tokenHandler)) { 1 } else { 0 }),
        ],
        [("asset_id", assets.at(assetId).symbol)],
      )
    );
  };
  for (assetId in Nat.range(0, auction.assets.nAssets())) {
    registerAssetMetrics_(assetId);
  };

  // ICRC84 API
  public shared query func principalToSubaccount(p : Principal) : async ?Blob = async ?TokenHandler.toSubaccount(p);

  public shared query func icrc84_supported_tokens() : async [Principal] {
    Array.tabulate<Principal>(
      assets.size(),
      func(i) = assets.at(i).ledgerPrincipal,
    );
  };

  public shared query func icrc84_token_info(token : Principal) : async ICRC84.TokenInfo {
    for ((i, assetInfo) in Iter.enumerate(assets.values())) {
      if (Principal.equal(assetInfo.ledgerPrincipal, token)) {
        return {
          deposit_fee = TokenHandler.fee(assetInfo.handler, #deposit);
          withdrawal_fee = TokenHandler.fee(assetInfo.handler, #withdrawal);
          allowance_fee = TokenHandler.fee(assetInfo.handler, #allowance);
        };
      };
    };
    throw Error.reject("Unknown token");
  };

  public shared query ({ caller }) func icrc84_query(arg : [Principal]) : async [(
    Principal,
    {
      credit : Int;
      tracked_deposit : ?Nat;
    },
  )] {
    let tokens : [Principal] = switch (arg.size()) {
      case (0) assets.map<AssetInfo, Principal>(func({ ledgerPrincipal }) = ledgerPrincipal) |> _.toArray();
      case (_) arg;
    };
    let ret : List.List<(Principal, { credit : Int; tracked_deposit : ?Nat })> = List.empty();
    for (token in tokens.values()) {
      let ?aid = getAssetId(token) else throw Error.reject("Unknown token " # Principal.toText(token));
      let credit = auction.getCredit(caller, aid).available;
      if (credit > 0) {
        let tracked_deposit = TokenHandler.trackedDeposit(assets.at(aid).handler, caller);
        ret.add((token, { credit; tracked_deposit }));
      };
    };
    ret.toArray();
  };

  private func notify(p : Principal, assetId : Auction.AssetId) : async* ICRC84.NotifyResponse {
    let assetInfo = assets.at(assetId);
    let result = try {
      await* TokenHandler.notify(assetInfo.handler, p, getTokenHandlerContext(assetInfo.ledgerPrincipal));
    } catch (err) {
      return #Err(#CallLedgerError({ message = Error.message(err) }));
    };
    switch (result) {
      case (?(depositInc, creditInc)) {
        let userCredit = TokenHandler.userCredit(assetInfo.handler, p);
        if (userCredit > 0) {
          let inc = Int.abs(userCredit);
          assert TokenHandler.debitUser(assetInfo.handler, p, inc, getTokenHandlerContext(assetInfo.ledgerPrincipal));
          ignore auction.appendCredit(p, assetId, inc);
          ignore auction.appendLoyaltyPoints(p, #wallet);
          #Ok({
            deposit_inc = depositInc;
            credit_inc = creditInc;
            credit = auction.getCredit(p, assetId).available;
          });
        } else {
          #Err(#NotAvailable({ message = "Deposit was not detected" }));
        };
      };
      case (null) #Err(#NotAvailable({ message = "Deposit was not detected" }));
    };
  };

  public shared ({ caller }) func icrc84_notify(args : ICRC84.NotifyArgs) : async ICRC84.NotifyResponse {
    notifyCounter.add(1);
    let ?assetId = getAssetId(args.token) else return #Err(#NotAvailable({ message = "Unknown token" }));
    await* notify(caller, assetId);
  };

  public shared ({ caller }) func icrc84_deposit(args : ICRC84.DepositArgs) : async ICRC84.DepositResponse {
    depositCounter.add(1);
    let ?assetId = getAssetId(args.token) else throw Error.reject("Unknown token");
    let assetInfo = assets.at(assetId);
    let res = await* TokenHandler.depositFromAllowance(assetInfo.handler, caller, args.from, args.amount, args.expected_fee, getTokenHandlerContext(args.token));
    switch (res) {
      case (#ok(creditInc, txid)) {
        let userCredit = TokenHandler.userCredit(assetInfo.handler, caller);
        if (userCredit > 0) {
          let credited = Int.abs(userCredit);
          assert TokenHandler.debitUser(assetInfo.handler, caller, credited, getTokenHandlerContext(assetInfo.ledgerPrincipal));
          ignore auction.appendCredit(caller, assetId, credited);
          ignore auction.appendLoyaltyPoints(caller, #wallet);
          #Ok({
            credit_inc = creditInc;
            txid = txid;
            credit = auction.getCredit(caller, assetId).available;
          });
        } else {
          #Err(#AmountBelowMinimum({}));
        };
      };
      case (#err x) #Err(
        switch (x) {
          case (#BadFee x) #BadFee(x);
          case (#CallIcrc1LedgerError) #CallLedgerError({
            message = "Call failed";
          });
          case (#InsufficientAllowance _) #TransferError({
            message = "Insufficient allowance";
          });
          case (#InsufficientFunds _) #TransferError({
            message = "Insufficient funds";
          });
          case (_) #TransferError({ message = "Unexpected error" });
        }
      );
    };
  };

  public shared ({ caller }) func icrc84_withdraw(args : ICRC84.WithdrawArgs) : async ICRC84.WithdrawResponse {
    withdrawCounter.add(1);
    let ?assetId = getAssetId(args.token) else throw Error.reject("Unknown token");
    let handler = assets.at(assetId).handler;
    let (rollbackCredit, doneCallback) = switch (auction.deductCredit(caller, assetId, args.amount)) {
      case (#err _) return #Err(#InsufficientCredit({}));
      case (#ok(_, r, d)) (r, d);
    };
    let res = await* TokenHandler.withdrawFromPool(handler, args.to, args.amount, args.expected_fee, getTokenHandlerContext(args.token));
    switch (res) {
      case (#ok(txid, amount)) {
        doneCallback();
        ignore auction.appendLoyaltyPoints(caller, #wallet);
        #Ok({ txid; amount });
      };
      case (#err err) {
        rollbackCredit();
        switch (err) {
          case (#BadFee x) #Err(#BadFee(x));
          case (#TooLowQuantity) #Err(#AmountBelowMinimum({}));
          case (#CallIcrc1LedgerError) #Err(#CallLedgerError({ message = "Call error" }));
          case (_) #Err(#CallLedgerError({ message = "Try later" }));
        };
      };
    };
  };

  transient let btcHandler : BtcHandler.BtcHandler = BtcHandler.BtcHandler(Principal.fromActor(self), CKBTC_LEDGER_PRINCIPAL, CKBTC_MINTER);

  public shared query ({ caller }) func btc_depositAddress(p : ?Principal) : async Text {
    let ?_ = getAssetId(CKBTC_LEDGER_PRINCIPAL) else throw Error.reject("BTC is not supported");
    btcHandler.calculateDepositAddress(Option.get(p, caller));
  };

  public shared ({ caller }) func btc_notify() : async BtcNotifyResult {
    let ?ckbtcAssetId = getAssetId(CKBTC_LEDGER_PRINCIPAL) else throw Error.reject("BTC is not supported");
    switch (await* btcHandler.notify(caller)) {
      case (#ok) await* notify(caller, ckbtcAssetId);
      case (#err err) #Err(err);
    };
  };

  public shared ({ caller }) func btc_withdraw(args : { to : Text; amount : Nat }) : async BtcWithdrawResult {
    let ?ckbtcAssetId = getAssetId(CKBTC_LEDGER_PRINCIPAL) else throw Error.reject("BTC is not supported");
    let handler = assets.at(ckbtcAssetId).handler;

    let (rollbackCredit, doneCallback) = switch (auction.deductCredit(caller, ckbtcAssetId, args.amount)) {
      case (#err _) return #Err(#InsufficientCredit({}));
      case (#ok(_, r, d)) (r, d);
    };
    let withdrawalResult = switch (
      await* btcHandler.withdraw(args.to, args.amount, TokenHandler.ledgerFee(handler))
    ) {
      case (#Err(#BadFee(_))) {
        // update fees in token handler and try again
        ignore await* TokenHandler.fetchFee(handler, getTokenHandlerContext(CKBTC_LEDGER_PRINCIPAL));
        await* btcHandler.withdraw(args.to, args.amount, TokenHandler.ledgerFee(handler));
      };
      case (#Err(x)) #Err(x);
      case (#Ok(x)) #Ok(x);
    };
    switch (withdrawalResult) {
      case (#Err err) {
        rollbackCredit();
        #Err(err);
      };
      case (#Ok { block_index }) {
        doneCallback();
        ignore auction.appendLoyaltyPoints(caller, #wallet);
        #Ok({ block_index });
      };
    };
  };
  public shared func btc_withdrawal_status(arg : { block_index : Nat64 }) : async BtcHandler.RetrieveBtcStatusV2 {
    await* btcHandler.getWithdrawalStatus(arg);
  };

  public shared ({ caller }) func cycles_withdraw(args : { to : Principal; amount : Nat }) : async DirectCyclesWithdrawResult {
    let ?cyclesAssetId = getAssetId(TCYCLES_LEDGER_PRINCIPAL) else throw Error.reject("Cycles asset is not supported");

    let ledgerFee = 100_000_000;
    if (args.amount <= ledgerFee) {
      return #Err(#TooLowAmount {});
    };

    let (rollbackCredit, doneCallback) = switch (auction.deductCredit(caller, cyclesAssetId, args.amount)) {
      case (#err _) return #Err(#InsufficientCredit({}));
      case (#ok(_, r, d)) (r, d);
    };
    let amount = Int.abs(args.amount - ledgerFee);
    switch (await tcyclesLedger.withdraw({ to = args.to; amount; from_subaccount = null; created_at_time = null })) {
      case (#Err err) {
        rollbackCredit();
        #Err(err);
      };
      case (#Ok txid) {
        doneCallback();
        ignore auction.appendLoyaltyPoints(caller, #wallet);
        #Ok({ txid; amount });
      };
    };
  };

  public shared query func getQuoteLedger() : async Principal {
    let ?quoteAsset = assets.get(0) else throw Error.reject("Not initialized");
    quoteAsset.ledgerPrincipal;
  };
  public shared query func nextSession() : async {
    timestamp : Nat;
    counter : Nat;
  } = async ({
    timestamp = nextSessionTimestamp;
    counter = auction.sessionsCounter;
  });

  public shared query func settings() : async {
    orderQuoteVolumeMinimum : Nat;
    orderQuoteVolumeStep : Nat;
    orderPriceDigitsLimit : Nat;
  } {
    {
      orderQuoteVolumeMinimum = auctionRuntime.minQuoteVolume;
      orderQuoteVolumeStep = auctionRuntime.quoteVolumeStep;
      orderPriceDigitsLimit = auctionRuntime.priceMaxDigits;
    };
  };

  public shared query func indicativeStats(icrc1Ledger : Principal) : async Auction.OrderBookInfo {
    let ?assetId = getAssetId(icrc1Ledger) else throw Error.reject("Unknown asset");
    if (assetId == 0) {
      throw Error.reject("Unknown asset");
    };
    auction.orderBookInfo(assetId, auctionRuntime);
  };

  public shared query func totalPointsSupply() : async Nat = async auction.getTotalLoyaltyPointsSupply();

  private func getIcrc1Ledger(assetId : Nat) : Principal = assets.at(assetId).ledgerPrincipal;
  private func getAssetId(icrc1Ledger : Principal) : ?Nat {
    for ((i, assetInfo) in Iter.enumerate(assets.values())) {
      if (Principal.equal(assetInfo.ledgerPrincipal, icrc1Ledger)) {
        return ?i;
      };
    };
    return null;
  };

  private func _auction_query(p : Principal, tokens : [Principal], selection : AuctionQuerySelection) : R.Result<AuctionQueryResponse, Principal> {
    let allAssetsMode = tokens.size() == 0;
    let (assetIds, baseAssetIds) : ([Auction.AssetId], [Auction.AssetId]) = if (allAssetsMode) {
      assert auction.quoteAssetId == 0;
      (
        Array.tabulate<Auction.AssetId>(auction.assets.nAssets(), func(i) = i),
        Array.tabulate<Auction.AssetId>(auction.assets.nAssets() - 1, func(i) = i + 1),
      );
    } else {
      let v : List.List<Auction.AssetId> = List.empty();
      let vBase : List.List<Auction.AssetId> = List.empty();
      for (p in tokens.values()) {
        let ?aid = getAssetId(p) else return #err(p);
        v.add(aid);
        if (aid != auction.quoteAssetId) {
          vBase.add(aid);
        };
      };
      (v.toArray(), vBase.toArray());
    };

    let user = auction.users.get(p);
    let historyListOrder = switch (selection.reversed_history) {
      case (?true) #desc;
      case (_) #asc;
    };

    // works with base assets only
    func retrieveElements<T>(select : ?Bool, getFunc : (?Auction.AssetId) -> [T]) : [T] {
      switch (select) {
        case (?true) {};
        case (_) return [];
      };
      if (allAssetsMode) {
        return getFunc(null);
      } else {
        let v : List.List<T> = List.empty();
        for (aid in baseAssetIds.values()) {
          v.addAll(getFunc(?aid).values());
        };
        v.toArray();
      };
    };

    let sessionNumbers = switch (selection.session_numbers) {
      case (?true) Array.map<Auction.AssetId, (Auction.AssetId, Nat)>(assetIds, func(aid) = (aid, auction.getAssetSessionNumber(aid)));
      case (_) [];
    };
    let credits = switch (selection.credits) {
      case (?true) if (allAssetsMode) {
        auction.getCredits(p);
      } else {
        Array.map<Auction.AssetId, (Auction.AssetId, Auction.CreditInfo)>(assetIds, func(aid) = (aid, auction.getCredit(p, aid)));
      };
      case (_) [];
    };
    let asks = retrieveElements<(Auction.OrderId, Auction.Order)>(selection.asks, func(assetId) = auction.getOrders(p, #ask, assetId));
    let bids = retrieveElements<(Auction.OrderId, Auction.Order)>(selection.bids, func(assetId) = auction.getOrders(p, #bid, assetId));
    let darkOrderBooks = retrieveElements<(Auction.AssetId, Auction.EncryptedOrderBook)>(
      selection.dark_order_books,
      func(assetId) = switch (assetId, user) {
        case (null, ?ui) ui.darkOrderBooks.entries().toArray();
        case (?aid, ?ui) ui.darkOrderBooks.get(aid) |> (
          switch (_) {
            case (?dob) [(aid, dob)];
            case (null) [];
          }
        );
        case (_) [];
      },
    );

    let depositHistory = switch (selection.deposit_history) {
      case (?(limit, skip)) {
        assetIds
        |> auction.getDepositHistory(p, _, historyListOrder)
        |> U.sliceIter(_, limit, skip);
      };
      case (null) [];
    };
    let transactionHistory = switch (selection.transaction_history) {
      case (?(limit, skip)) {
        assetIds
        |> auction.getTransactionHistory(p, _, historyListOrder)
        |> U.sliceIter(_, limit, skip);
      };
      case (null) [];
    };

    let priceHistory = switch (selection.price_history) {
      case (?(limit, skip, skipEmpty)) {
        baseAssetIds
        |> auction.getPriceHistory(_, historyListOrder, skipEmpty)
        |> U.sliceIter(_, limit, skip);
      };
      case (null) [];
    };
    let immediatePriceHistory = switch (selection.immediate_price_history) {
      case (?(limit, skip)) {
        baseAssetIds
        |> auction.getImmediatePriceHistory(_, historyListOrder)
        |> U.sliceIter(_, limit, skip);
      };
      case (null) [];
    };

    let lastPrices = switch (selection.last_prices) {
      case (?true) {
        var pendingAssetIds = PureList.fromArray(baseAssetIds);
        auction.getPriceHistory([], #desc, true)
        |> Iter.filter<Auction.PriceHistoryItem>(
          _,
          func(item : Auction.PriceHistoryItem) {
            let (upd, deletedAid) = U.listFindOneAndDelete<Auction.AssetId>(pendingAssetIds, func(x) = Nat.equal(x, item.2));
            switch (deletedAid) {
              case (?_) {
                pendingAssetIds := upd;
                true;
              };
              case (null) false;
            };
          },
        )
        |> U.sliceIter(_, baseAssetIds.size(), 0);
      };
      case (_) [];
    };
    let lastImmediatePrices = switch (selection.last_immediate_prices) {
      case (?true) {
        var pendingAssetIds = PureList.fromArray(baseAssetIds);
        auction.getImmediatePriceHistory([], #desc)
        |> Iter.filter<Auction.PriceHistoryItem>(
          _,
          func(item : Auction.PriceHistoryItem) {
            let (upd, deletedAid) = U.listFindOneAndDelete<Auction.AssetId>(pendingAssetIds, func(x) = Nat.equal(x, item.2));
            switch (deletedAid) {
              case (?_) {
                pendingAssetIds := upd;
                true;
              };
              case (null) false;
            };
          },
        )
        |> U.sliceIter(_, baseAssetIds.size(), 0);
      };
      case (_) [];
    };

    func mapHistoryItem(x : Auction.PriceHistoryItem) : PriceHistoryItem {
      (x.0, x.1, assets.at(x.2).ledgerPrincipal, x.3, x.4);
    };
    #ok({
      session_numbers = sessionNumbers |> Array.tabulate<(Principal, Nat)>(_.size(), func(i) = (getIcrc1Ledger(_[i].0), _[i].1));
      asks = asks |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = (_[i].0, mapOrder(_[i].1)));
      bids = bids |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = (_[i].0, mapOrder(_[i].1)));
      credits = credits |> Array.tabulate<(Principal, Auction.CreditInfo)>(_.size(), func(i) = (getIcrc1Ledger(_[i].0), _[i].1));
      dark_order_books = darkOrderBooks |> Array.tabulate<(Principal, Auction.EncryptedOrderBook)>(_.size(), func(i) = (getIcrc1Ledger(_[i].0), _[i].1));
      deposit_history = depositHistory |> Array.map<Auction.DepositHistoryItem, DepositHistoryItem>(_, func(x) = (x.0, x.1, assets.at(x.2).ledgerPrincipal, x.3));
      transaction_history = transactionHistory |> Array.map<Auction.TransactionHistoryItem, TransactionHistoryItem>(_, func(x) = (x.0, x.1, x.2, assets.at(x.3).ledgerPrincipal, x.4, x.5));
      price_history = priceHistory |> Array.map<Auction.PriceHistoryItem, PriceHistoryItem>(_, mapHistoryItem);
      immediate_price_history = immediatePriceHistory |> Array.map<Auction.PriceHistoryItem, PriceHistoryItem>(_, mapHistoryItem);
      last_prices = lastPrices |> Array.map<Auction.PriceHistoryItem, PriceHistoryItem>(_, mapHistoryItem);
      last_immediate_prices = lastImmediatePrices |> Array.map<Auction.PriceHistoryItem, PriceHistoryItem>(_, mapHistoryItem);
      order_book_info = switch (selection.order_book_info) {
        case (?true) baseAssetIds |> Array.map<Auction.AssetId, (Principal, Auction.OrderBookInfo)>(
          _,
          func(aid) = (assets.at(aid).ledgerPrincipal, auction.orderBookInfo(aid, auctionRuntime)),
        );
        case (_) [];
      };
      immediate_order_book_info = switch (selection.immediate_order_book_info) {
        case (?true) baseAssetIds |> Array.map<Auction.AssetId, (Principal, Auction.ImmediateOrderBookInfo)>(
          _,
          func(aid) = (assets.at(aid).ledgerPrincipal, auction.immediateOrderBookInfo(aid, auctionRuntime)),
        );
        case (_) [];
      };
      points = auction.getLoyaltyPoints(p);
      account_revision = auction.getAccountRevision(p);
    });
  };

  public shared query ({ caller }) func auction_query(tokens : [Principal], selection : AuctionQuerySelection) : async AuctionQueryResponse {
    switch (_auction_query(caller, tokens, selection)) {
      case (#ok ret) ret;
      case (#err p) throw Error.reject("Unknown token " # Principal.toText(p));
    };
  };

  private func drainPushNotifications() : async* () {
    let q = auctionRuntime.stagedPushNotifications;
    let buf = List.empty<(Principal, NotificationDelegate.NotificationBody)>();
    label l while (not Queue.isEmpty(q)) {
      let ?(p, n) = Queue.popFront(q) else break l;
      buf.add((
        p,
        switch (n) {
          case (#orderFulfilled { assetId; kind; price; baseVolume; quoteVolume; isPartial }) {
            let baseDecimals = assets.at(assetId).decimals;
            let quoteDecimals = assets.at(auction.quoteAssetId).decimals;
            let priceLog10Multiplier : Int = baseDecimals - quoteDecimals;
            {
              title = "Order fulfillment";
              content = "Your "
              # (switch (kind) { case (#ask) "ask "; case (#bid) "bid " })
              # "on " # assets.at(assetId).symbol
              # " was "
              # (if (isPartial) { "partially " } else { "" })
              # "fulfilled. Price: " # TextUtils.floatToSig5(FloatUtils.scaleFloat(price, priceLog10Multiplier))
              # "; Base volume: " # TextUtils.natWithDecimalsToText(baseVolume, baseDecimals)
              # "; Quote volume: " # TextUtils.natWithDecimalsToText(quoteVolume, quoteDecimals);
              url = null;
              tag = null;
            };
          };
        },
      ));
    };
    let items = buf.toArray();
    if (items.size() > 0) {
      try {
        ignore await NotificationDelegate.getActor().sendNotifications(items);
      } catch (err) {
        Prim.debugPrint("[push] sendNotifications failed: " # Error.message(err));
      };
    };
  };

  public shared ({ caller }) func manageOrders(
    cancellations : ?{
      #all : ?[Principal];
      #orders : [{ #ask : Auction.OrderId; #bid : Auction.OrderId }];
    },
    placements : [{
      #ask : (token : Principal, orderBookType : Auction.OrderBookType, volume : Nat, price : Float);
      #bid : (token : Principal, orderBookType : Auction.OrderBookType, volume : Nat, price : Float);
    }],
    expectedAccountRevision : ?Nat,
  ) : async UpperResult<([ICRC84Auction.CancellationResult], [Auction.PlaceOrderResult]), ICRC84Auction.ManageOrdersError> {
    manageOrdersCounter.add(1);
    let cancellationArg : ?Auction.CancellationAction = switch (cancellations) {
      case (null) null;
      case (?#orders x) ?#orders(x);
      case (?#all null) ?#all(null);
      case (?#all(?tokens)) {
        let aids = VarArray.repeat<Nat>(0, tokens.size());
        for (i in tokens.keys()) {
          let ?aid = getAssetId(tokens[i]) else return #Err(#cancellation({ index = i; error = #UnknownAsset }));
          aids[i] := aid;
        };
        ?#all(?VarArray.toArray(aids));
      };
    };
    let placementArg = VarArray.repeat<Auction.PlaceOrderAction>(#ask(0, #delayed, 0, 0.0), placements.size());
    for (i in placements.keys()) {
      let placement = placements[i];
      let token = switch (placement) { case (#ask x or #bid x) x.0 };
      let ?aid = getAssetId(token) else return #Err(#placement({ index = i; error = #UnknownAsset }));
      placementArg[i] := switch (placement) {
        case (#ask(_, orderBookType, volume, price)) #ask(aid, orderBookType, volume, price);
        case (#bid(_, orderBookType, volume, price)) #bid(aid, orderBookType, volume, price);
      };
    };
    let ret = auction.manageOrders(caller, cancellationArg, VarArray.toArray(placementArg), expectedAccountRevision, auctionRuntime)
    |> ICRC84Auction.mapManageOrdersResult(_, getIcrc1Ledger);
    await* drainPushNotifications();
    ret;
  };

  public shared ({ caller }) func manageDarkOrderBooks(args : [(Principal, ?Auction.EncryptedOrderBook)], expectedAccountRevision : ?Nat) : async UpperResult<[?Auction.EncryptedOrderBook], { #AccountRevisionMismatch; #UnknownAsset : Principal; #UnknownPrincipal; #NoCredit }> {
    manageDarkOrderBooksCounter.add(1);
    let pureArgs = VarArray.repeat<(Auction.AssetId, ?Auction.EncryptedOrderBook)>((0, null), args.size());
    for (i in args.keys()) {
      let ?assetId = getAssetId(args[i].0) else return #Err(#UnknownAsset(args[i].0));
      pureArgs[i] := (assetId, args[i].1);
    };
    auction.manageDarkOrderBooks(caller, VarArray.toArray(pureArgs), expectedAccountRevision, auctionRuntime) |> R.toUpper(_);
  };

  public shared ({ caller }) func placeBids(arg : [(ledger : Principal, orderBookType : Auction.OrderBookType, volume : Nat, price : Float)], expectedAccountRevision : ?Nat) : async [UpperResult<Auction.PlaceOrderResult, ICRC84Auction.PlaceOrderError>] {
    orderPlacementCounter.add(1);
    let ret = Array.tabulate<UpperResult<Auction.PlaceOrderResult, ICRC84Auction.PlaceOrderError>>(
      arg.size(),
      func(i) {
        let ?assetId = getAssetId(arg[i].0) else return #Err(#UnknownAsset);
        auction.placeOrder(caller, #bid, assetId, arg[i].1, arg[i].2, arg[i].3, expectedAccountRevision, auctionRuntime)
        |> R.toUpper(_);
      },
    );
    await* drainPushNotifications();
    ret;
  };

  public shared ({ caller }) func replaceBid(orderId : Auction.OrderId, volume : Nat, price : Float, expectedAccountRevision : ?Nat) : async UpperResult<Auction.PlaceOrderResult, ICRC84Auction.ReplaceOrderError> {
    orderReplacementCounter.add(1);
    let ret = auction.replaceOrder(caller, #bid, orderId, volume : Nat, price : Float, expectedAccountRevision, auctionRuntime)
    |> R.toUpper(_);
    await* drainPushNotifications();
    ret;
  };

  public shared ({ caller }) func cancelBids(orderIds : [Auction.OrderId], expectedAccountRevision : ?Nat) : async [UpperResult<ICRC84Auction.CancellationResult, ICRC84Auction.CancelOrderError>] {
    orderCancellationCounter.add(1);
    Array.tabulate<UpperResult<ICRC84Auction.CancellationResult, ICRC84Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = auction.cancelOrder(caller, #bid, orderIds[i], expectedAccountRevision, auctionRuntime) |> ICRC84Auction.mapCancelOrderResult(_, getIcrc1Ledger),
    );
  };

  public shared ({ caller }) func placeAsks(arg : [(ledger : Principal, orderBookType : Auction.OrderBookType, volume : Nat, price : Float)], expectedAccountRevision : ?Nat) : async [UpperResult<Auction.PlaceOrderResult, ICRC84Auction.PlaceOrderError>] {
    orderPlacementCounter.add(1);
    let ret = Array.tabulate<UpperResult<Auction.PlaceOrderResult, ICRC84Auction.PlaceOrderError>>(
      arg.size(),
      func(i) {
        let ?assetId = getAssetId(arg[i].0) else return #Err(#UnknownAsset);
        auction.placeOrder(caller, #ask, assetId, arg[i].1, arg[i].2, arg[i].3, expectedAccountRevision, auctionRuntime)
        |> R.toUpper(_);
      },
    );
    await* drainPushNotifications();
    ret;
  };

  public shared ({ caller }) func replaceAsk(orderId : Auction.OrderId, volume : Nat, price : Float, expectedAccountRevision : ?Nat) : async UpperResult<Auction.PlaceOrderResult, ICRC84Auction.ReplaceOrderError> {
    orderReplacementCounter.add(1);
    let ret = auction.replaceOrder(caller, #ask, orderId, volume : Nat, price : Float, expectedAccountRevision, auctionRuntime)
    |> R.toUpper(_);
    await* drainPushNotifications();
    ret;
  };

  public shared ({ caller }) func cancelAsks(orderIds : [Auction.OrderId], expectedAccountRevision : ?Nat) : async [UpperResult<ICRC84Auction.CancellationResult, ICRC84Auction.CancelOrderError>] {
    orderCancellationCounter.add(1);
    Array.tabulate<UpperResult<ICRC84Auction.CancellationResult, ICRC84Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = auction.cancelOrder(caller, #ask, orderIds[i], expectedAccountRevision, auctionRuntime) |> ICRC84Auction.mapCancelOrderResult(_, getIcrc1Ledger),
    );
  };

  type SharedUserSettings = {
    pushNotificationsEnabled : Bool;
  };
  private func shareUserSettings(s : Auction.UserSettings) : SharedUserSettings = {
    pushNotificationsEnabled = s.pushNotificationsEnabled;
  };

  public query ({ caller }) func getUserSettings() : async SharedUserSettings {
    let ?user = auction.users.get(caller) else throw Error.reject("Unknown principal");
    shareUserSettings(user.userSettings);
  };

  public shared ({ caller }) func updateUserSettings(
    settings : {
      pushNotificationsEnabled : ?Bool;
    }
  ) : async SharedUserSettings {
    let ?user = auction.users.get(caller) else throw Error.reject("Unknown principal");
    switch (settings.pushNotificationsEnabled) {
      case (null) {};
      case (?v) user.userSettings.pushNotificationsEnabled := v;
    };
    shareUserSettings(user.userSettings);
  };

  public func updateTokenHandlerFee(ledger : Principal) : async ?Nat {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    let assetInfo = assets.at(assetId);
    await* TokenHandler.fetchFee(assetInfo.handler, getTokenHandlerContext(assetInfo.ledgerPrincipal));
  };

  public query func isTokenHandlerFrozen(ledger : Principal) : async Bool {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    TokenHandler.isFrozen(assets.at(assetId).handler);
  };

  public query func queryTokenHandlerState(ledger : Principal) : async {
    balance : {
      deposited : Nat;
      underway : Nat;
      queued : Nat;
      consolidated : Nat;
      usableDeposit : (deposit : Int, correct : Bool);
    };
    flow : {
      consolidated : Nat;
      withdrawn : Nat;
    };
    credit : {
      total : Int;
      pool : Int;
    };
    users : {
      queued : Nat;
      locked : Nat;
      total : Nat;
    };
    depositManager : {
      paused : Bool;
      totalConsolidated : Nat;
      totalCredited : Nat;
      funds : {
        deposited : Nat;
        underway : Nat;
        queued : Nat;
      };
    };
    withdrawalManager : {
      totalWithdrawn : Nat;
      lockedFunds : Nat;
    };
    feeManager : {
      ledger : Nat;
      deposit : Nat;
      surcharge : Nat;
      outstandingFees : Nat;
    };
  } {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    TokenHandler.state(assets.at(assetId).handler);
  };

  public query func queryUserCreditsInTokenHandler(ledger : Principal, user : Principal) : async Int {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    TokenHandler.userCredit(assets.at(assetId).handler, user);
  };

  public query func queryTokenHandlerNotificationsOnPause(ledger : Principal) : async Bool {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    TokenHandler.notificationsOnPause(assets.at(assetId).handler);
  };

  public query func queryTokenHandlerJournal(ledger : Principal, limit : Nat, skip : Nat) : async [(Principal, TokenHandler.LogEvent)] {
    tokenHandlersJournal.values()
    |> Iter.filter<(Principal, Principal, TokenHandler.LogEvent)>(_, func(l, _, _) = Principal.equal(l, ledger))
    |> Iter.map<(Principal, Principal, TokenHandler.LogEvent), (Principal, TokenHandler.LogEvent)>(_, func(_, p, e) = (p, e))
    |> U.sliceIter(_, limit, skip);
  };

  public shared ({ caller }) func registerAsset(ledger : Principal, minAskVolume : Nat) : async UpperResult<Nat, RegisterAssetError> {
    await* assertAdminAccess(caller);
    let res = await* registerAsset_(ledger, minAskVolume);
    R.toUpper(res);
  };

  public shared ({ caller }) func wipeOrders() : async () {
    await* assertAdminAccess(caller);
    for (p in auction.users.usersLookup.keys()) {
      ignore auction.manageOrders(p, ?#all(null), [], null, auctionRuntime);
    };
  };

  public shared query ({ caller }) func user_auction_query(user : Principal, tokens : [Principal], selection : AuctionQuerySelection) : async AuctionQueryResponse {
    assertAdminAccessSync(caller);
    switch (_auction_query(user, tokens, selection)) {
      case (#ok ret) ret;
      case (#err p) throw Error.reject("Unknown token " # Principal.toText(p));
    };
  };

  public shared query ({ caller }) func queryOrderBook(icrc1Ledger : Principal) : async {
    asks : {
      immediate : [(Auction.OrderId, UserOrder)];
      delayed : [(Auction.OrderId, UserOrder)];
    };
    bids : {
      immediate : [(Auction.OrderId, UserOrder)];
      delayed : [(Auction.OrderId, UserOrder)];
    };
  } {
    assertAdminAccessSync(caller);
    let ?assetId = getAssetId(icrc1Ledger) else throw Error.reject("Unknown asset");
    func mapOrdersList(orderBook : [(Auction.OrderId, Auction.Order)]) : [(Auction.OrderId, UserOrder)] = Array.tabulate<(Auction.OrderId, UserOrder)>(orderBook.size(), func(i) = (orderBook[i].0, mapUserOrder(orderBook[i].1)));
    {
      asks = {
        immediate = mapOrdersList(auction.listAssetOrders(assetId, #ask, #immediate));
        delayed = mapOrdersList(auction.listAssetOrders(assetId, #ask, #delayed));
      };
      bids = {
        immediate = mapOrdersList(auction.listAssetOrders(assetId, #bid, #immediate));
        delayed = mapOrdersList(auction.listAssetOrders(assetId, #bid, #delayed));
      };
    };
  };

  // Auction processing functionality

  transient var nextAssetIdToProcess : Nat = 0;
  // total instructions sent on last auction processing routine. Accumulated in case processing was splitted to few heartbeat calls
  transient var lastBidProcessingInstructions : Nat64 = 0;
  // amount of chunks, used for processing all assets
  transient var lastBidProcessingChunks : Nat8 = 0;
  // when spent instructions on bids processing exceeds this value, we stop iterating over assets and commit processed ones.
  // Canister will continue processing them on next heartbeat
  transient let BID_PROCESSING_INSTRUCTIONS_THRESHOLD : Nat64 = 1_000_000_000;

  transient var vetKey : ?Blob = null;

  // loops over asset ids, beginning from provided asset id and processes them one by one.
  // stops if we exceed instructions threshold and returns #nextIndex in this case
  private func processAssetsChunk(auction : Auction.Auction, startIndex : Nat) : async* {
    #done;
    #nextIndex : Nat;
  } {
    let startInstructions = Prim.performanceCounter(0);
    if (startIndex == 0) {
      vetKey := null;
    };
    let newSwapRates : List.List<(Auction.AssetId, Float)> = List.empty();
    newSwapRates.add((auction.quoteAssetId, 1.0));
    var nextAssetId = 0;
    label l for (assetId in Nat.range(startIndex, assets.size())) {
      if (assetId == auction.quoteAssetId) continue l;
      nextAssetId := assetId + 1;
      if (auction.nDarkOrderBooks(assetId) > 0) {
        switch (cryptoCanisterId, vetKey) {
          case (?ccid, ?vk) await* Auction.decryptDarkOrderBooks(auction, assetId, ccid, vk);
          case (?ccid, null) {
            try {
              let vk = await* E.decryptVetKey(ccid, Text.encodeUtf8(Nat.toText(nextSessionTimestamp)));
              await* Auction.decryptDarkOrderBooks(auction, assetId, ccid, vk);
              vetKey := ?vk;
            } catch (err) {
              Prim.debugPrint("Cannot decrypt vetkey: " # Error.message(err));
            };
          };
          case (null, _) Prim.debugPrint("Cannot decrypt dark order books: crypto canister id not set");
        };
      };
      auction.processAsset(assetId, auctionRuntime);
      if (Prim.performanceCounter(0) > startInstructions + BID_PROCESSING_INSTRUCTIONS_THRESHOLD) break l;
    };
    if (startIndex == 0) {
      lastBidProcessingInstructions := Prim.performanceCounter(0) - startInstructions;
      lastBidProcessingChunks := 1;
    } else {
      lastBidProcessingInstructions += Prim.performanceCounter(0) - startInstructions;
      lastBidProcessingChunks += 1;
    };
    if (nextAssetId == assets.size()) {
      #done();
    } else {
      #nextIndex(nextAssetId);
    };
  };

  func runAuction() : async () {
    if (nextAssetIdToProcess == 0) {
      let startTimeDiff : Int = Nat64.toNat(Prim.time() / 1_000_000) - nextAuctionTickTimestamp * 1_000;
      sessionStartTimeGauge.update(Int.max(startTimeDiff, 0) |> Int.abs(_));
      let next = Nat64.toNat(auctionSchedule.nextExecutionAt() / 1_000_000_000);
      if (next == nextAuctionTickTimestamp) {
        // if auction started before expected time
        nextAuctionTickTimestamp += Nat64.toNat(AUCTION_INTERVAL_SECONDS);
      } else {
        nextAuctionTickTimestamp := next;
      };
    };
    switch (await* processAssetsChunk(auction, nextAssetIdToProcess)) {
      case (#done) {
        auction.sessionsCounter += 1;
        nextSessionTimestamp := Nat64.toNat(auctionSchedule.nextExecutionAt() / 1_000_000_000);
        nextAssetIdToProcess := 0;
      };
      case (#nextIndex next) {
        if (next == nextAssetIdToProcess) {
          Prim.trap("Can never happen: not a single asset processed");
        };
        nextAssetIdToProcess := next;
        ignore runAuction();
      };
    };
  };

  // A timer for consolidating backlog subaccounts, runs each minute at 30th second
  transient let consolidationSchedule = Scheduler.Scheduler(
    60,
    30,
    func(_ : Nat) : async* () {
      for (asset in assets.values()) {
        await* TokenHandler.trigger(asset.handler, 10, getTokenHandlerContext(asset.ledgerPrincipal));
      };
    },
  );
  if (consolidationTimerEnabled) {
    consolidationSchedule.start<system>();
  };

  public shared ({ caller }) func setConsolidationTimerEnabled(enabled : Bool) : async () {
    await* assertAdminAccess(caller);
    consolidationTimerEnabled := enabled;
    if (enabled) {
      consolidationSchedule.start<system>();
    } else {
      consolidationSchedule.stop();
    };
  };

  transient var _runAuction : () -> async () = func() : async () {};
  transient let auctionSchedule = Scheduler.Scheduler(
    AUCTION_INTERVAL_SECONDS,
    0,
    func(counter : Nat) : async* () {
      if (counter == 0) {
        sessionStartTimeBaseOffsetMetric.set(Nat64.toNat((Prim.time() / 1_000_000) % (AUCTION_INTERVAL_SECONDS * 1_000)));
      };
      await _runAuction();
    },
  );
  _runAuction := runAuction;

  auctionSchedule.start<system>();

  public shared ({ caller }) func restartAuctionTimer() : async () {
    await* assertAdminAccess(caller);
    auctionSchedule.stop();
    auctionSchedule.start<system>();
  };

  // If assets are empty, register quote asset
  if (assets.size() == 0) {
    ignore Timer.setTimer<system>(
      #seconds(0),
      func() : async () {
        let quoteLedgerPrincipal = U.requireMsg(quoteLedger_, "Quote ledger principal not provided");
        ignore U.requireOk(await* registerAsset_(quoteLedgerPrincipal, 0));
      },
    );
  };

};
