import Array "mo:base/Array";
import Error "mo:base/Error";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import R "mo:base/Result";
import Text "mo:base/Text";
import Timer "mo:base/Timer";

import ICRC84 "mo:icrc-84";
import PT "mo:promtracker";
import TokenHandler "mo:token-handler";
import Vec "mo:vector";

import Auction "./auction/src";
import AssetOrderBook "./auction/src/asset_order_book";
import ICRC84Auction "./icrc84_auction";

import BtcHandler "./btc_handler";
import HTTP "./utils/http";
import Permissions "./utils/permissions";
import Scheduler "./utils/scheduler";
import U "./utils";

// arguments have to be provided on first canister install,
// on upgrade quote ledger will be ignored
actor class Icrc1AuctionAPI(quoteLedger_ : ?Principal, adminPrincipal_ : ?Principal) = self {

  // ensure compliance to ICRC84 standart.
  // actor won't compile in case of type mismatch here
  let _ : ICRC84.ICRC84 = self;

  stable let trustedLedgerPrincipal : Principal = U.requireMsg(quoteLedger_, "Quote ledger principal not provided");
  stable let quoteLedgerPrincipal : Principal = trustedLedgerPrincipal;

  stable var stableAdminsMap : Permissions.StableDataV1 = Permissions.defaultStableDataV1();
  let permissions : Permissions.Permissions = Permissions.Permissions(stableAdminsMap, adminPrincipal_);

  stable var assetsDataV1 : Vec.Vector<StableAssetInfoV1> = Vec.new();

  stable var auctionDataV1 : Auction.StableDataV1 = Auction.defaultStableDataV1();
  stable var auctionDataV2 : Auction.StableDataV2 = Auction.migrateStableDataV2(auctionDataV1);

  stable var ptData : PT.StableData = null;

  stable var tokenHandlersJournal : Vec.Vector<(ledger : Principal, p : Principal, logEvent : TokenHandler.LogEvent)> = Vec.new();

  stable var consolidationTimerEnabled : Bool = true;

  // constants
  let AUCTION_INTERVAL_SECONDS : Nat64 = 120;

  // Bitcoin mainnet
  let CKBTC_LEDGER_PRINCIPAL = Principal.fromText("mxzaz-hqaaa-aaaar-qaada-cai");
  let CKBTC_MINTER = {
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

  let TCYCLES_LEDGER_PRINCIPAL = Principal.fromText("um5iw-rqaaa-aaaaq-qaaba-cai");
  let tcyclesLedger : (
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
  type StableAssetInfoV1 = {
    ledgerPrincipal : Principal;
    minAskVolume : Nat;
    handler : TokenHandler.StableData;
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
    icrc1Ledger = Vec.get(assets, order.assetId).ledgerPrincipal;
    volume = order.volume;
  });

  type UserOrder = {
    user : Principal;
    price : Float;
    volume : Nat;
  };
  func mapUserOrder(order : Auction.Order) : UserOrder = ({
    user = order.user;
    price = order.price;
    volume = order.volume;
  });

  type UpperResult<Ok, Err> = { #Ok : Ok; #Err : Err };

  type AuctionQuerySelection = {
    session_numbers : ?Bool;
    asks : ?Bool;
    bids : ?Bool;
    credits : ?Bool;
    deposit_history : ?(limit : Nat, skip : Nat);
    transaction_history : ?(limit : Nat, skip : Nat);
    price_history : ?(limit : Nat, skip : Nat, skipEmpty : Bool);
    immediate_price_history : ?(limit : Nat, skip : Nat);
    reversed_history : ?Bool;
    last_prices : ?Bool;
  };

  type AuctionQueryResponse = {
    session_numbers : [(Principal, Nat)];
    asks : [(Auction.OrderId, Order)];
    bids : [(Auction.OrderId, Order)];
    credits : [(Principal, Auction.CreditInfo)];
    deposit_history : [DepositHistoryItem];
    transaction_history : [TransactionHistoryItem];
    price_history : [PriceHistoryItem];
    immediate_price_history : [PriceHistoryItem];
    last_prices : [PriceHistoryItem];
    points : Nat;
    account_revision : Nat;
  };

  type WithdrawalMemo = {
    #icrc1Address : (Principal, ?Blob);
    #btcDirect : Text;
    #cyclesDirect : Principal;
  };

  type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, ledgerPrincipal : Principal, volume : Nat, price : Float);
  type DepositHistoryItem = (timestamp : Nat64, kind : { #deposit; #withdrawal : ?WithdrawalMemo }, ledgerPrincipal : Principal, volume : Nat);
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

  let quoteAssetId : Auction.AssetId = 0;

  func createAssetInfo_(ledgerPrincipal : Principal, minAskVolume : Nat, decimals : Nat, symbol : Text, tokenHandlerStableData : ?TokenHandler.StableData) : AssetInfo {
    let ai = TokenHandler.buildLedgerApi(ledgerPrincipal)
    |> {
      ledgerPrincipal = ledgerPrincipal;
      minAskVolume = minAskVolume;
      handler = TokenHandler.TokenHandler({
        ledgerApi = _;
        ownPrincipal = Principal.fromActor(self);
        initialFee = 0;
        triggerOnNotifications = true;
        log = func(p : Principal, logEvent : TokenHandler.LogEvent) = Vec.add(tokenHandlersJournal, (ledgerPrincipal, p, logEvent));
      });
      decimals;
      symbol;
    };
    switch (tokenHandlerStableData) {
      case (?d) ai.handler.unshare(d);
      case (null) {};
    };
    ai;
  };

  let assets : Vec.Vector<AssetInfo> = Vec.map<StableAssetInfoV1, AssetInfo>(
    assetsDataV1,
    func(x) = createAssetInfo_(x.ledgerPrincipal, x.minAskVolume, x.decimals, x.symbol, ?x.handler),
  );
  let auction : Auction.Auction = Auction.Auction(
    0,
    {
      volumeStepLog10 = 3; // minimum quote volume step 1_000
      minVolumeSteps = 5; // minimum quote volume is 5_000
      priceMaxDigits = 5;
      minAskVolume = func(assetId, _) = Vec.get(assets, assetId).minAskVolume;
      performanceCounter = Prim.performanceCounter;
    },
  );
  auction.unshare(auctionDataV2);

  // will be set in startAuctionTimer_
  // this timestamp is set right before starting auction execution
  var nextAuctionTickTimestamp = 0;
  // this timestamp is set after auction session executed completely, sycnhronized with auction.sessionsCounter
  var nextSessionTimestamp = 0;

  private func registerAsset_(ledgerPrincipal : Principal, minAskVolume : Nat) : async* R.Result<Nat, RegisterAssetError> {
    let id = Vec.size(assets);
    assert id == auction.assets.nAssets();
    if (id == 0 and not Principal.equal(ledgerPrincipal, quoteLedgerPrincipal)) {
      Prim.trap("Cannot register another token before registering quote");
    };
    let canister = actor (Principal.toText(ledgerPrincipal)) : (actor { icrc1_decimals : () -> async Nat8; icrc1_symbol : () -> async Text });
    let decimalsCall = canister.icrc1_decimals();
    let symbolCall = canister.icrc1_symbol();
    let decimals = Nat8.toNat(await decimalsCall);
    let symbol = await symbolCall;

    if (Vec.forSome<AssetInfo>(assets, func(a) = Principal.equal(ledgerPrincipal, a.ledgerPrincipal))) {
      return #err(#AlreadyRegistered);
    };
    createAssetInfo_(ledgerPrincipal, minAskVolume, decimals, symbol, null) |> Vec.add<AssetInfo>(assets, _);
    auction.registerAssets(1);
    registerAssetMetrics_(id);
    #ok(id);
  };

  let metrics = PT.PromTracker("", 65);
  metrics.addSystemValues();
  let sessionStartTimeBaseOffsetMetric = metrics.addCounter("session_start_time_base_offset", "", false);
  let sessionStartTimeGauge = metrics.addGauge("session_start_time_offset_ms", "", #none, [0, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 64_000, 128_000], false);
  let startupTime = Prim.time();
  ignore metrics.addPullValue("uptime", "", func() = Nat64.toNat((Prim.time() - startupTime) / 1_000_000_000));
  ignore metrics.addPullValue("sessions_counter", "", func() = auction.sessionsCounter);
  ignore metrics.addPullValue("assets_count", "", func() = auction.assets.nAssets());
  ignore metrics.addPullValue("users_count", "", func() = auction.users.nUsers());
  ignore metrics.addPullValue("users_with_credits_count", "", func() = auction.users.nUsersWithCredits());
  ignore metrics.addPullValue("accounts_count", "", func() = auction.credits.nAccounts());
  ignore metrics.addPullValue("quote_surplus", "", func() = auction.credits.quoteSurplus);
  ignore metrics.addPullValue("next_session_timestamp", "", func() = nextAuctionTickTimestamp);
  ignore metrics.addPullValue("total_unique_participants", "", func() = auction.users.participantsArchiveSize);
  ignore metrics.addPullValue("active_unique_participants", "", func() = auction.users.nUsersWithActiveOrders());
  ignore metrics.addPullValue(
    "monthly_active_participants_count",
    "",
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
  );
  ignore metrics.addPullValue("total_orders", "", func() = auction.orders.ordersCounter);
  ignore metrics.addPullValue("auctions_run_count", "", func() = auction.assets.historyLength(#delayed));
  ignore metrics.addPullValue("trading_pairs_count", "", func() = auction.assets.nAssets() - 1);
  ignore metrics.addPullValue("total_points_supply", "", func() = auction.getTotalLoyaltyPointsSupply());

  // call stats
  let notifyCounter = metrics.addCounter("total_calls__icrc84_notify", "", true);
  let depositCounter = metrics.addCounter("total_calls__icrc84_deposit", "", true);
  let withdrawCounter = metrics.addCounter("total_calls__icrc84_withdraw", "", true);
  let manageOrdersCounter = metrics.addCounter("total_calls__manageOrders", "", true);
  let orderPlacementCounter = metrics.addCounter("total_calls__order_placement", "", true);
  let orderReplacementCounter = metrics.addCounter("total_calls__order_replacement", "", true);
  let orderCancellationCounter = metrics.addCounter("total_calls__order_cancellation", "", true);

  private func registerAssetMetrics_(assetId : Auction.AssetId) {
    let tokenHandler = Vec.get(assets, assetId).handler;
    let labels = "asset_id=\"" # Vec.get(assets, assetId).symbol # "\"";

    if (assetId != quoteAssetId) {
      let asset = auction.assets.getAsset(assetId);

      let priceMultiplier = 10 ** Float.fromInt(Vec.get(assets, assetId).decimals);
      let renderPrice = func(price : Float) : Nat = Int.abs(Float.toInt(price * priceMultiplier));

      ignore metrics.addPullValue("asks_count", labels # ",order_book=\"immediate\"", func() = asset.asks.immediate.size);
      ignore metrics.addPullValue("asks_volume", labels # ",order_book=\"immediate\"", func() = asset.asks.immediate.totalVolume);
      ignore metrics.addPullValue("asks_count", labels # ",order_book=\"delayed\"", func() = asset.asks.delayed.size);
    ignore metrics.addPullValue("asks_volume", labels # ",order_book=\"delayed\"", func() = asset.asks.delayed.totalVolume);

    ignore metrics.addPullValue("bids_count", labels # ",order_book=\"immediate\"", func() = asset.bids.immediate.size);
      ignore metrics.addPullValue("bids_volume", labels # ",order_book=\"immediate\"", func() = asset.bids.immediate.totalVolume);
    ignore metrics.addPullValue("bids_count", labels # ",order_book=\"delayed\"", func() = asset.bids.delayed.size);
    ignore metrics.addPullValue("bids_volume", labels # ",order_book=\"delayed\"", func() = asset.bids.delayed.totalVolume);

      ignore metrics.addPullValue("processing_instructions", labels, func() = asset.lastProcessingInstructions);
      ignore metrics.addPullValue("total_executed_volume_base", labels, func() = asset.totalExecutedVolumeBase);
      ignore metrics.addPullValue("total_executed_volume_quote", labels, func() = asset.totalExecutedVolumeQuote);
      ignore metrics.addPullValue("total_executed_orders", labels, func() = asset.totalExecutedOrders);

      ignore metrics.addPullValue(
        "clearing_price",
        labels,
        func() = auction.indicativeAssetStats(assetId)
        |> (switch (_.clearing) { case (#match x) { x.price }; case (_) { 0.0 } })
        |> renderPrice(_),
      );
      ignore metrics.addPullValue(
        "clearing_volume",
        labels,
        func() = auction.indicativeAssetStats(assetId)
        |> (switch (_.clearing) { case (#match x) { x.volume }; case (_) { 0 } }),
      );

      ignore metrics.addPullValue(
        "last_price",
        labels,
        func() = auction.getPriceHistory([assetId], #desc, false).next()
        |> (
          switch (_) {
            case (?item) renderPrice(item.4);
            case (null) 0;
          }
        ),
      );
      ignore metrics.addPullValue(
        "last_volume",
        labels,
        func() = auction.getPriceHistory([assetId], #desc, false).next()
        |> (
          switch (_) {
            case (?item) item.3;
            case (null) 0;
          }
        ),
      );
    };
    ignore metrics.addPullValue(
      "token_handler_locks",
      labels,
      func() = tokenHandler.state().users.locked,
    );
    ignore metrics.addPullValue(
      "token_handler_frozen",
      labels,
      func() = if (tokenHandler.isFrozen()) { 1 } else { 0 },
    );
  };
  for (assetId in Iter.range(0, auction.assets.nAssets() - 1)) {
    registerAssetMetrics_(assetId);
  };
  metrics.unshare(ptData);

  // ICRC84 API
  public shared query func principalToSubaccount(p : Principal) : async ?Blob = async ?TokenHandler.toSubaccount(p);

  public shared query func icrc84_supported_tokens() : async [Principal] {
    Array.tabulate<Principal>(
      Vec.size(assets),
      func(i) = Vec.get(assets, i).ledgerPrincipal,
    );
  };

  public shared query func icrc84_token_info(token : Principal) : async ICRC84.TokenInfo {
    for ((assetInfo, i) in Vec.items(assets)) {
      if (Principal.equal(assetInfo.ledgerPrincipal, token)) {
        return {
          deposit_fee = assetInfo.handler.fee(#deposit);
          withdrawal_fee = assetInfo.handler.fee(#withdrawal);
          allowance_fee = assetInfo.handler.fee(#allowance);
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
      case (0) Vec.map<AssetInfo, Principal>(assets, func({ ledgerPrincipal }) = ledgerPrincipal) |> Vec.toArray(_);
      case (_) arg;
    };
    let ret : Vec.Vector<(Principal, { credit : Int; tracked_deposit : ?Nat })> = Vec.new();
    for (token in tokens.vals()) {
      let ?aid = getAssetId(token) else throw Error.reject("Unknown token " # Principal.toText(token));
      let credit = auction.getCredit(caller, aid).available;
      if (credit > 0) {
        let tracked_deposit = Vec.get(assets, aid).handler.trackedDeposit(caller);
        Vec.add(ret, (token, { credit; tracked_deposit }));
      };
    };
    Vec.toArray(ret);
  };

  private func notify(p : Principal, assetId : Auction.AssetId) : async* ICRC84.NotifyResponse {
    let assetInfo = Vec.get(assets, assetId);
    let result = try {
      await* assetInfo.handler.notify(p);
    } catch (err) {
      return #Err(#CallLedgerError({ message = Error.message(err) }));
    };
    switch (result) {
      case (?(depositInc, creditInc)) {
        let userCredit = assetInfo.handler.userCredit(p);
        if (userCredit > 0) {
          let inc = Int.abs(userCredit);
          assert assetInfo.handler.debitUser(p, inc);
          ignore auction.appendCredit(p, assetId, inc, null);
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
    let assetInfo = Vec.get(assets, assetId);
    let res = await* assetInfo.handler.depositFromAllowance(caller, args.from, args.amount, args.expected_fee);
    switch (res) {
      case (#ok(creditInc, txid)) {
        let userCredit = assetInfo.handler.userCredit(caller);
        if (userCredit > 0) {
          let credited = Int.abs(userCredit);
          assert assetInfo.handler.debitUser(caller, credited);
          ignore auction.appendCredit(caller, assetId, credited, null);
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
    let handler = Vec.get(assets, assetId).handler;
    let withdrawalMemo = to_candid (#icrc1Address(args.to.owner, args.to.subaccount) : WithdrawalMemo);
    let (rollbackCredit, doneCallback) = switch (auction.deductCredit(caller, assetId, args.amount, ?withdrawalMemo)) {
      case (#err _) return #Err(#InsufficientCredit({}));
      case (#ok(_, r, d)) (r, d);
    };
    let res = await* handler.withdrawFromPool(args.to, args.amount, args.expected_fee);
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

  let btcHandler : BtcHandler.BtcHandler = BtcHandler.BtcHandler(Principal.fromActor(self), CKBTC_LEDGER_PRINCIPAL, CKBTC_MINTER);

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
    let handler = Vec.get(assets, ckbtcAssetId).handler;
    let withdrawalMemo = to_candid (#btcDirect(args.to) : WithdrawalMemo);

    let (rollbackCredit, doneCallback) = switch (auction.deductCredit(caller, ckbtcAssetId, args.amount, ?withdrawalMemo)) {
      case (#err _) return #Err(#InsufficientCredit({}));
      case (#ok(_, r, d)) (r, d);
    };
    let withdrawalResult = switch (
      await* btcHandler.withdraw(args.to, args.amount, handler.ledgerFee())
    ) {
      case (#Err(#BadFee(_))) {
        // update fees in token handler and try again
        ignore await* handler.fetchFee();
        await* btcHandler.withdraw(args.to, args.amount, handler.ledgerFee());
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
    let withdrawalMemo = to_candid (#cyclesDirect(args.to) : WithdrawalMemo);

    let (rollbackCredit, doneCallback) = switch (auction.deductCredit(caller, cyclesAssetId, args.amount, ?withdrawalMemo)) {
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

  public shared query func getQuoteLedger() : async Principal = async quoteLedgerPrincipal;
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
      orderQuoteVolumeMinimum = auction.orders.minQuoteVolume;
      orderQuoteVolumeStep = auction.orders.quoteVolumeStep;
      orderPriceDigitsLimit = auction.orders.priceMaxDigits;
    };
  };

  public shared query func indicativeStats(icrc1Ledger : Principal) : async Auction.IndicativeStats {
    if (icrc1Ledger == quoteLedgerPrincipal) throw Error.reject("Unknown asset");
    let ?assetId = getAssetId(icrc1Ledger) else throw Error.reject("Unknown asset");
    auction.indicativeAssetStats(assetId);
  };

  public shared query func totalPointsSupply() : async Nat = async auction.getTotalLoyaltyPointsSupply();

  private func getIcrc1Ledger(assetId : Nat) : Principal = Vec.get(assets, assetId).ledgerPrincipal;
  private func getAssetId(icrc1Ledger : Principal) : ?Nat {
    for ((assetInfo, i) in Vec.items(assets)) {
      if (Principal.equal(assetInfo.ledgerPrincipal, icrc1Ledger)) {
        return ?i;
      };
    };
    return null;
  };

  private func _auction_query(p : Principal, tokens : [Principal], selection : AuctionQuerySelection) : R.Result<AuctionQueryResponse, Principal> {

    func retrieveElements<T>(select : ?Bool, getFunc : (?Auction.AssetId) -> [T]) : R.Result<[T], Principal> {
      switch (select) {
        case (?true) {};
        case (_) return #ok([]);
      };
      switch (tokens.size()) {
        case (0) #ok(getFunc(null));
        case (_) {
          let v : Vec.Vector<T> = Vec.new();
          for (p in tokens.vals()) {
            let ?assetId = getAssetId(p) else return #err(p);
            Vec.addFromIter(v, getFunc(?assetId).vals());
          };
          #ok(Vec.toArray(v));
        };
      };
    };

    func mapLedgersToAssetIds(tokens : [Principal]) : R.Result<[Nat], Principal> {
      let res = Array.init<Nat>(tokens.size(), 0);
      for (i in tokens.keys()) {
        let ?assetId = getAssetId(tokens[i]) else return #err(tokens[i]);
        res[i] := assetId;
      };
      #ok(Array.freeze(res));
    };

    let (sessionNumbers, asks, bids, credits) = switch (
      retrieveElements<(Auction.AssetId, Nat)>(
        selection.session_numbers,
        func(assetId) = switch (assetId) {
          case (null) Array.tabulate<(Auction.AssetId, Nat)>(auction.assets.nAssets(), func(i) = (i, auction.getAssetSessionNumber(i)));
          case (?aid) [(aid, auction.getAssetSessionNumber(aid))];
        },
      ),
      retrieveElements<(Auction.OrderId, Auction.Order)>(selection.asks, func(assetId) = auction.getOrders(p, #ask, assetId)),
      retrieveElements<(Auction.OrderId, Auction.Order)>(selection.bids, func(assetId) = auction.getOrders(p, #bid, assetId)),
      retrieveElements<(Auction.AssetId, Auction.CreditInfo)>(
        selection.credits,
        func(assetId) = switch (assetId) {
          case (null) auction.getCredits(p);
          case (?aid) [(aid, auction.getCredit(p, aid))];
        },
      ),
    ) {
      case (#ok sn, #ok a, #ok b, #ok c) (sn, a, b, c);
      case ((#err p, _, _, _) or (_, #err p, _, _) or (_, _, #err p, _) or (_, _, _, #err p)) return #err(p);
    };
    let historyListOrder = switch (selection.reversed_history) {
      case (?true) #desc;
      case (_) #asc;
    };
    #ok({
      session_numbers = sessionNumbers |> Array.tabulate<(Principal, Nat)>(_.size(), func(i) = (getIcrc1Ledger(_ [i].0), _ [i].1));
      asks = asks |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = (_ [i].0, mapOrder(_ [i].1)));
      bids = bids |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = (_ [i].0, mapOrder(_ [i].1)));
      credits = credits |> Array.tabulate<(Principal, Auction.CreditInfo)>(_.size(), func(i) = (getIcrc1Ledger(_ [i].0), _ [i].1));
      deposit_history = switch (selection.deposit_history) {
        case (?(limit, skip)) {
          (
            switch (mapLedgersToAssetIds(tokens)) {
              case (#ok aids) aids;
              case (#err p) return #err(p);
            }
          )
          |> auction.getDepositHistory(p, _, historyListOrder)
          |> U.sliceIter(_, limit, skip)
          |> Array.map<Auction.DepositHistoryItem, DepositHistoryItem>(
            _,
            func(x) = (
              x.0,
              switch (x.1) {
                case (#deposit _) #deposit;
                case (#withdrawal null) #withdrawal(null);
                case (#withdrawal(?memo)) {
                  let info : ?WithdrawalMemo = from_candid memo;
                  #withdrawal(info);
                };
              },
              Vec.get(assets, x.2).ledgerPrincipal,
              x.3,
            ),
          );
        };
        case (null) [];
      };
      transaction_history = switch (selection.transaction_history) {
        case (?(limit, skip)) {
          (
            switch (mapLedgersToAssetIds(tokens)) {
              case (#ok aids) aids;
              case (#err p) return #err(p);
            }
          )
          |> auction.getTransactionHistory(p, _, historyListOrder)
          |> U.sliceIter(_, limit, skip)
          |> Array.map<Auction.TransactionHistoryItem, TransactionHistoryItem>(_, func(x) = (x.0, x.1, x.2, Vec.get(assets, x.3).ledgerPrincipal, x.4, x.5));
        };
        case (null) [];
      };
      price_history = switch (selection.price_history) {
        case (?(limit, skip, skipEmpty)) {
          (
            switch (mapLedgersToAssetIds(tokens)) {
              case (#ok aids) aids;
              case (#err p) return #err(p);
            }
          )
          |> auction.getPriceHistory(_, historyListOrder, skipEmpty)
          |> U.sliceIter(_, limit, skip)
          |> Array.map<Auction.PriceHistoryItem, PriceHistoryItem>(_, func(x) = (x.0, x.1, Vec.get(assets, x.2).ledgerPrincipal, x.3, x.4));
        };
        case (null) [];
      };
      immediate_price_history = switch (selection.immediate_price_history) {
        case (?(limit, skip)) {
          (
            switch (mapLedgersToAssetIds(tokens)) {
              case (#ok aids) aids;
              case (#err p) return #err(p);
            }
          )
          |> auction.getImmediatePriceHistory(_, historyListOrder)
          |> U.sliceIter(_, limit, skip)
          |> Array.map<Auction.PriceHistoryItem, PriceHistoryItem>(_, func(x) = (x.0, x.1, Vec.get(assets, x.2).ledgerPrincipal, x.3, x.4));
        };
        case (null) [];
      };
      last_prices = switch (selection.last_prices) {
        case (?true) {
          let (assetIds : List.List<Auction.AssetId>, itemsAmount : Nat) = switch (tokens.size()) {
            case (0) (Iter.toList(Vec.keys(auction.assets.assets)), auction.assets.nAssets());
            case (_) {
              var list : List.List<Auction.AssetId> = List.nil();
              for (p in tokens.vals()) {
                let ?aid = getAssetId(p) else return #err(p);
                list := List.push(aid, list);
              };
              (list, tokens.size());
            };
          };
          var pendingAssetIds = assetIds;
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
          |> U.sliceIter(_, itemsAmount, 0)
          |> Array.map<Auction.PriceHistoryItem, PriceHistoryItem>(_, func(x) = (x.0, x.1, Vec.get(assets, x.2).ledgerPrincipal, x.3, x.4));
        };
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
        let aids = Array.init<Nat>(tokens.size(), 0);
        for (i in tokens.keys()) {
          let ?aid = getAssetId(tokens[i]) else return #Err(#cancellation({ index = i; error = #UnknownAsset }));
          aids[i] := aid;
        };
        ?#all(?Array.freeze(aids));
      };
    };
    let placementArg = Array.init<Auction.PlaceOrderAction>(placements.size(), #ask(0, #delayed, 0, 0.0));
    for (i in placements.keys()) {
      let placement = placements[i];
      let token = switch (placement) { case (#ask x or #bid x) x.0 };
      let ?aid = getAssetId(token) else return #Err(#placement({ index = i; error = #UnknownAsset }));
      placementArg[i] := switch (placement) {
        case (#ask(_, orderBookType, volume, price)) #ask(aid, orderBookType, volume, price);
        case (#bid(_, orderBookType, volume, price)) #bid(aid, orderBookType, volume, price);
      };
    };
    auction.manageOrders(caller, cancellationArg, Array.freeze(placementArg), expectedAccountRevision)
    |> ICRC84Auction.mapManageOrdersResult(_, getIcrc1Ledger);
  };

  public shared ({ caller }) func placeBids(arg : [(ledger : Principal, orderBookType : Auction.OrderBookType, volume : Nat, price : Float)], expectedAccountRevision : ?Nat) : async [UpperResult<Auction.PlaceOrderResult, ICRC84Auction.PlaceOrderError>] {
    orderPlacementCounter.add(1);
    Array.tabulate<UpperResult<Auction.PlaceOrderResult, ICRC84Auction.PlaceOrderError>>(
      arg.size(),
      func(i) {
        let ?assetId = getAssetId(arg[i].0) else return #Err(#UnknownAsset);
        auction.placeOrder(caller, #bid, assetId, arg[i].1, arg[i].2, arg[i].3, expectedAccountRevision)
        |> R.toUpper(_);
      },
    );
  };

  public shared ({ caller }) func replaceBid(orderId : Auction.OrderId, volume : Nat, price : Float, expectedAccountRevision : ?Nat) : async UpperResult<Auction.PlaceOrderResult, ICRC84Auction.ReplaceOrderError> {
    orderReplacementCounter.add(1);
    auction.replaceOrder(caller, #bid, orderId, volume : Nat, price : Float, expectedAccountRevision)
    |> R.toUpper(_);
  };

  public shared ({ caller }) func cancelBids(orderIds : [Auction.OrderId], expectedAccountRevision : ?Nat) : async [UpperResult<ICRC84Auction.CancellationResult, ICRC84Auction.CancelOrderError>] {
    orderCancellationCounter.add(1);
    Array.tabulate<UpperResult<ICRC84Auction.CancellationResult, ICRC84Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = auction.cancelOrder(caller, #bid, orderIds[i], expectedAccountRevision) |> ICRC84Auction.mapCancelOrderResult(_, getIcrc1Ledger),
    );
  };

  public shared ({ caller }) func placeAsks(arg : [(ledger : Principal, orderBookType : Auction.OrderBookType, volume : Nat, price : Float)], expectedAccountRevision : ?Nat) : async [UpperResult<Auction.PlaceOrderResult, ICRC84Auction.PlaceOrderError>] {
    orderPlacementCounter.add(1);
    Array.tabulate<UpperResult<Auction.PlaceOrderResult, ICRC84Auction.PlaceOrderError>>(
      arg.size(),
      func(i) {
        let ?assetId = getAssetId(arg[i].0) else return #Err(#UnknownAsset);
        auction.placeOrder(caller, #ask, assetId, arg[i].1, arg[i].2, arg[i].3, expectedAccountRevision)
        |> R.toUpper(_);
      },
    );
  };

  public shared ({ caller }) func replaceAsk(orderId : Auction.OrderId, volume : Nat, price : Float, expectedAccountRevision : ?Nat) : async UpperResult<Auction.PlaceOrderResult, ICRC84Auction.ReplaceOrderError> {
    orderReplacementCounter.add(1);
    auction.replaceOrder(caller, #ask, orderId, volume : Nat, price : Float, expectedAccountRevision)
    |> R.toUpper(_);
  };

  public shared ({ caller }) func cancelAsks(orderIds : [Auction.OrderId], expectedAccountRevision : ?Nat) : async [UpperResult<ICRC84Auction.CancellationResult, ICRC84Auction.CancelOrderError>] {
    orderCancellationCounter.add(1);
    Array.tabulate<UpperResult<ICRC84Auction.CancellationResult, ICRC84Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = auction.cancelOrder(caller, #ask, orderIds[i], expectedAccountRevision) |> ICRC84Auction.mapCancelOrderResult(_, getIcrc1Ledger),
    );
  };

  public func updateTokenHandlerFee(ledger : Principal) : async ?Nat {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    await* Vec.get(assets, assetId) |> _.handler.fetchFee();
  };

  public query func isTokenHandlerFrozen(ledger : Principal) : async Bool {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    Vec.get(assets, assetId) |> _.handler.isFrozen();
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
    Vec.get(assets, assetId) |> _.handler.state();
  };

  public query func queryUserCreditsInTokenHandler(ledger : Principal, user : Principal) : async Int {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    Vec.get(assets, assetId) |> _.handler.userCredit(user);
  };

  public query func queryTokenHandlerNotificationsOnPause(ledger : Principal) : async Bool {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    Vec.get(assets, assetId) |> _.handler.notificationsOnPause();
  };

  public query func queryTokenHandlerJournal(ledger : Principal, limit : Nat, skip : Nat) : async [(Principal, TokenHandler.LogEvent)] {
    Vec.vals(tokenHandlersJournal)
    |> Iter.filter<(Principal, Principal, TokenHandler.LogEvent)>(_, func(l, _, _) = Principal.equal(l, ledger))
    |> Iter.map<(Principal, Principal, TokenHandler.LogEvent), (Principal, TokenHandler.LogEvent)>(_, func(_, p, e) = (p, e))
    |> U.sliceIter(_, limit, skip);
  };

  public query func listAdmins() : async [Principal] = async permissions.listAdmins();

  public shared ({ caller }) func addAdmin(principal : Principal) : async () {
    await* permissions.assertAdminAccess(caller);
    permissions.addAdmin(principal);
  };

  public shared ({ caller }) func removeAdmin(principal : Principal) : async () {
    if (Principal.equal(principal, caller)) {
      throw Error.reject("Cannot remove yourself from admins");
    };
    await* permissions.assertAdminAccess(caller);
    permissions.removeAdmin(principal);
  };

  public shared ({ caller }) func registerAsset(ledger : Principal, minAskVolume : Nat) : async UpperResult<Nat, RegisterAssetError> {
    await* permissions.assertAdminAccess(caller);
    let res = await* registerAsset_(ledger, minAskVolume);
    R.toUpper(res);
  };

  public shared ({ caller }) func wipePriceHistory(icrc1Ledger : Principal) : async () {
    await* permissions.assertAdminAccess(caller);
    let ?assetId = getAssetId(icrc1Ledger) else throw Error.reject("Unknown asset");
    let newHistory : Vec.Vector<Auction.PriceHistoryItem> = Vec.new();
    for (x in Vec.vals(auction.assets.history.delayed)) {
      if (x.2 != assetId) {
        Vec.add(newHistory, x);
      };
    };
    auction.assets.history.delayed := newHistory;
  };

  public shared ({ caller }) func wipeOrders() : async () {
    await* permissions.assertAdminAccess(caller);
    for ((p, _) in auction.users.users.entries()) {
      ignore auction.manageOrders(p, ?#all(null), [], null);
    };
  };

  public shared ({ caller }) func wipeUsers() : async () {
    await* permissions.assertAdminAccess(caller);
    for ((p, _) in auction.users.users.entries()) {
      auction.users.users.delete(p);
    };
    for (asset in Vec.vals(auction.assets.assets)) {
      AssetOrderBook.clear(asset.asks.immediate);
      AssetOrderBook.clear(asset.asks.delayed);
      AssetOrderBook.clear(asset.bids.immediate);
      AssetOrderBook.clear(asset.bids.delayed);
    };
  };

  public shared query ({ caller }) func user_auction_query(user : Principal, tokens : [Principal], selection : AuctionQuerySelection) : async AuctionQueryResponse {
    permissions.assertAdminAccessSync(caller);
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
    permissions.assertAdminAccessSync(caller);
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

  var nextAssetIdToProcess : Nat = 0;
  // total instructions sent on last auction processing routine. Accumulated in case processing was splitted to few heartbeat calls
  var lastBidProcessingInstructions : Nat64 = 0;
  // amount of chunks, used for processing all assets
  var lastBidProcessingChunks : Nat8 = 0;
  // when spent instructions on bids processing exceeds this value, we stop iterating over assets and commit processed ones.
  // Canister will continue processing them on next heartbeat
  let BID_PROCESSING_INSTRUCTIONS_THRESHOLD : Nat64 = 1_000_000_000;

  // loops over asset ids, beginning from provided asset id and processes them one by one.
  // stops if we exceed instructions threshold and returns #nextIndex in this case
  private func processAssetsChunk(auction : Auction.Auction, startIndex : Nat) : {
    #done;
    #nextIndex : Nat;
  } {
    let startInstructions = Prim.performanceCounter(0);
    let newSwapRates : Vec.Vector<(Auction.AssetId, Float)> = Vec.new();
    Vec.add(newSwapRates, (quoteAssetId, 1.0));
    var nextAssetId = 0;
    label l for (assetId in Iter.range(startIndex, Vec.size(assets) - 1)) {
      nextAssetId := assetId + 1;
      auction.processAsset(assetId);
      if (Prim.performanceCounter(0) > startInstructions + BID_PROCESSING_INSTRUCTIONS_THRESHOLD) break l;
    };
    if (startIndex == 0) {
      lastBidProcessingInstructions := Prim.performanceCounter(0) - startInstructions;
      lastBidProcessingChunks := 1;
    } else {
      lastBidProcessingInstructions += Prim.performanceCounter(0) - startInstructions;
      lastBidProcessingChunks += 1;
    };
    if (nextAssetId == Vec.size(assets)) {
      #done();
    } else {
      #nextIndex(nextAssetId);
    };
  };

  private func runAuction() : async () {
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
    switch (processAssetsChunk(auction, nextAssetIdToProcess)) {
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

  public query func http_request(req : HTTP.HttpRequest) : async HTTP.HttpResponse {
    let ?path = Text.split(req.url, #char '?').next() else return HTTP.render400();
    switch (req.method, path) {
      case ("GET", "/metrics") metrics.renderExposition("canister=\"" # PT.shortName(self) # "\"") |> HTTP.renderPlainText(_);
      case (_) HTTP.render400();
    };
  };

  system func preupgrade() {
    assetsDataV1 := Vec.map<AssetInfo, StableAssetInfoV1>(
      assets,
      func(x) = {
        ledgerPrincipal = x.ledgerPrincipal;
        minAskVolume = x.minAskVolume;
        handler = x.handler.share();
        decimals = x.decimals;
        symbol = x.symbol;
      },
    );
    auctionDataV2 := auction.share();
    ptData := metrics.share();
    stableAdminsMap := permissions.share();
  };

  // A timer for consolidating backlog subaccounts, runs each minute at 30th second
  let consolidationSchedule = Scheduler.Scheduler(
    60,
    30,
    func(_ : Nat) : async* () {
      for (asset in Vec.vals(assets)) {
        await* asset.handler.trigger(10);
      };
    },
  );
  if (consolidationTimerEnabled) {
    consolidationSchedule.start<system>();
  };

  public shared ({ caller }) func setConsolidationTimerEnabled(enabled : Bool) : async () {
    await* permissions.assertAdminAccess(caller);
    consolidationTimerEnabled := enabled;
    if (enabled) {
      consolidationSchedule.start<system>();
    } else {
      consolidationSchedule.stop();
    };
  };

  var _runAuction : () -> async () = func() : async () {};
  let auctionSchedule = Scheduler.Scheduler(
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
    await* permissions.assertAdminAccess(caller);
    auctionSchedule.stop();
    auctionSchedule.start<system>();
  };

  // If assets are empty, register quote asset
  if (Vec.size(assets) == 0) {
    ignore Timer.setTimer<system>(
      #seconds(0),
      func() : async () {
        ignore U.requireOk(await* registerAsset_(quoteLedgerPrincipal, 0));
      },
    );
  };

};
