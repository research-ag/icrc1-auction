import Array "mo:base/Array";
import AssocList "mo:base/AssocList";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import R "mo:base/Result";
import RBTree "mo:base/RBTree";
import Timer "mo:base/Timer";

import PT "mo:promtracker";
import Vec "mo:vector";

import U "./utils";

module {

  type AssetId = Nat;

  public type StableData = {
    sessionsCounter : Nat;
    assets : Vec.Vector<StableAssetInfo>;
    users : RBTree.Tree<Principal, UserInfo>;
    history : List.List<AssetHistoryItem>;
  };

  public func defaultStableData() : StableData = {
    sessionsCounter = 0;
    assets = Vec.new();
    users = #leaf;
    history = null;
  };

  public type Account = {
    // balance of user account
    var credit : Nat;
    // user's credit, placed as bid or ask
    var lockedCredit : Nat;
  };

  public type AssetHistoryItem = (timestamp : Nat64, sessionNumber : Nat, assetId : AssetId, volume : Nat, price : Float);
  public type OrderHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float);

  public type Order = {
    user : Principal;
    userInfoRef : UserInfo;
    assetId : AssetId;
    price : Float;
    var volume : Nat;
  };

  public type SharedOrder = {
    assetId : AssetId;
    price : Float;
    volume : Nat;
  };

  public type UserInfo = {
    var currentAsks : AssocList.AssocList<AssetId, Order>;
    var currentBids : AssocList.AssocList<AssetId, Order>;
    var credits : AssocList.AssocList<AssetId, Account>;
    var history : List.List<OrderHistoryItem>;
  };

  public type StableAssetInfo = {
    asks : List.List<Order>;
    bids : List.List<Order>;
    lastSwapRate : Float;
  };

  public type AssetInfo = {
    var asks : List.List<Order>;
    var bids : List.List<Order>;
    var lastSwapRate : Float;
    metrics : {
      bidsAmount : PT.CounterValue;
      totalBidVolume : PT.CounterValue;
      asksAmount : PT.CounterValue;
      totalAskVolume : PT.CounterValue;
      lastProcessingInstructions : PT.CounterValue;
    };
  };

  public type OrderError = { #UnknownPrincipal; #UnknownAsset };
  public type PlaceOrderError = OrderError or { #NoCredit; #TooLowOrder };

  // when spent instructions on bids processing exceeds this value, we stop iterating over assets and commit processed ones.
  // Canister will continue processing them on next heartbeat
  let BID_PROCESSING_INSTRUCTIONS_THRESHOLD : Nat64 = 1_000_000_000;
  // minimum price*volume for placing a bid or an ask. Assuming that trusted token is ICP with 8 decimals,
  // it gives 0.005 ICP: For ICP price $20 it is $0.10
  let MINIMUM_ORDER = 500_000;

  public func getTotalPrice(volume : Nat, unitPrice : Float) : Nat = Int.abs(Float.toInt(Float.ceil(unitPrice * Float.fromInt(volume))));

  public class Auction<system>(
    trustedAssetId : AssetId,
    metrics : PT.PromTracker,
    settings : {
      minAskVolume : (AssetId, AssetInfo) -> Int;
    },
    hooks : {
      preAuction : ?(() -> async* ());
      postAuction : ?(() -> async* ());
    },
  ) {

    // a counter of conducted auction sessions
    public var sessionsCounter = 0;
    // asset info, index == assetId
    public var assets : Vec.Vector<AssetInfo> = Vec.new();
    // user info
    public let users : RBTree.RBTree<Principal, UserInfo> = RBTree.RBTree<Principal, UserInfo>(Principal.compare);
    // asset history
    public var history : List.List<AssetHistoryItem> = null;

    metrics.addSystemValues();
    ignore metrics.addPullValue("sessions_counter", "", func() = sessionsCounter);
    ignore metrics.addPullValue("assets_amount", "", func() = Vec.size(assets));
    let metricUsersAmount = metrics.addCounter("users_amount", "", true);
    let metricAccountsAmount = metrics.addCounter("accounts_amount", "", true);
    public func initAssetMetrics(assetId : AssetId) : {
      asksAmount : PT.CounterValue;
      totalAskVolume : PT.CounterValue;
      bidsAmount : PT.CounterValue;
      totalBidVolume : PT.CounterValue;
      lastProcessingInstructions : PT.CounterValue;
    } = {
      asksAmount = metrics.addCounter("asks_amount", "asset_id=\"" # Nat.toText(assetId) # "\"", true);
      totalAskVolume = metrics.addCounter("asks_volume", "asset_id=\"" # Nat.toText(assetId) # "\"", true);
      bidsAmount = metrics.addCounter("bids_amount", "asset_id=\"" # Nat.toText(assetId) # "\"", true);
      totalBidVolume = metrics.addCounter("bids_volume", "asset_id=\"" # Nat.toText(assetId) # "\"", true);
      lastProcessingInstructions = metrics.addCounter("processing_instructions", "asset_id=\"" # Nat.toText(assetId) # "\"", true);
    };

    public func initUser(p : Principal) : UserInfo {
      let data : UserInfo = {
        var currentAsks = null;
        var currentBids = null;
        var credits = null;
        var history = null;
      };
      let oldValue = users.replace(p, data);
      switch (oldValue) {
        case (?v) Prim.trap("Prevented user data overwrite");
        case (_) {};
      };
      metricUsersAmount.add(1);
      data;
    };

    public func registerAssets(n : Nat) {
      var assetsVecSize = Vec.size(assets);
      let newAmount = assetsVecSize + n;
      while (assetsVecSize < newAmount) {
        (
          {
            var asks = List.nil();
            var bids = List.nil();
            var lastSwapRate = 0;
            metrics = initAssetMetrics(assetsVecSize);
          } : AssetInfo
        )
        |> Vec.add(assets, _);
        assetsVecSize += 1;
      };
    };

    public func queryCredit(p : Principal, assetId : AssetId) : Nat = users.get(p)
    |> Option.chain<UserInfo, Account>(_, func(info) = AssocList.find(info.credits, assetId, Nat.equal))
    |> Option.map<Account, Nat>(_, func(acc) = acc.credit - acc.lockedCredit)
    |> Option.get(_, 0);

    public func queryCredits(p : Principal) : [(AssetId, Nat)] = switch (users.get(p)) {
      case (null) [];
      case (?ui) {
        let length = List.size(ui.credits);
        var list = ui.credits;
        Array.tabulate<(AssetId, Nat)>(
          length,
          func(i) {
            let popped = List.pop(list);
            list := popped.1;
            switch (popped.0) {
              case null { loop { assert false } };
              case (?x) (x.0, x.1.credit - x.1.lockedCredit);
            };
          },
        );
      };
    };

    private func queryOrder_(p : Principal, assetId : AssetId, f : (ui : UserInfo) -> AssocList.AssocList<AssetId, Order>) : ?SharedOrder = users.get(p)
    |> Option.chain<UserInfo, Order>(_, func(info) = AssocList.find(f(info), assetId, Nat.equal))
    |> Option.map<Order, SharedOrder>(_, func(x) = { x with volume = x.volume });

    private func queryOrders_(p : Principal, f : (ui : UserInfo) -> AssocList.AssocList<AssetId, Order>) : [SharedOrder] = switch (users.get(p)) {
      case (null) [];
      case (?ui) {
        var list = f(ui);
        let length = List.size(list);
        Array.tabulate<SharedOrder>(
          length,
          func(i) {
            let popped = List.pop(list);
            list := popped.1;
            switch (popped.0) {
              case null { loop { assert false } };
              case (?x) x.1 |> { _ with volume = _.volume };
            };
          },
        );
      };
    };

    public func queryAsk(p : Principal, assetId : AssetId) : ?SharedOrder = queryOrder_(p, assetId, func(info) = info.currentAsks);
    public func queryBid(p : Principal, assetId : AssetId) : ?SharedOrder = queryOrder_(p, assetId, func(info) = info.currentBids);

    public func queryAsks(p : Principal) : [SharedOrder] = queryOrders_(p, func(info) = info.currentAsks);
    public func queryBids(p : Principal) : [SharedOrder] = queryOrders_(p, func(info) = info.currentBids);

    private func sliceList<T>(list : List.List<T>, limit : Nat, skip : Nat) : [T] {
      var tail = list;
      var i = 0;
      while (i < skip) {
        let ?(_, next) = tail else return [];
        tail := next;
        i += 1;
      };
      let ret : Vec.Vector<T> = Vec.new();
      i := 0;
      label l while (i < limit) {
        let ?(item, next) = tail else break l;
        Vec.add(ret, item);
        tail := next;
        i += 1;
      };
      Vec.toArray(ret);
    };

    public func queryHistory(p : Principal, limit : Nat, skip : Nat) : [OrderHistoryItem] {
      let ?userInfo = users.get(p) else return [];
      sliceList(userInfo.history, limit, skip);
    };

    public func queryAssetHistory(limit : Nat, skip : Nat) : [AssetHistoryItem] = sliceList(history, limit, skip);

    public func appendCredit(p : Principal, assetId : AssetId, amount : Nat) : Nat {
      let userInfo = switch (users.get(p)) {
        case (?info) info;
        case (null) initUser(p);
      };
      switch (AssocList.find<AssetId, Account>(userInfo.credits, assetId, Nat.equal)) {
        case (?acc) {
          acc.credit += amount;
          acc.credit - acc.lockedCredit;
        };
        case (null) {
          { var credit = amount; var lockedCredit = 0 }
          |> AssocList.replace<AssetId, Account>(userInfo.credits, assetId, Nat.equal, ?_)
          |> (userInfo.credits := _.0);
          metricAccountsAmount.add(1);
          amount;
        };
      };
    };

    public func setCredit(p : Principal, assetId : AssetId, credit : Nat) : Nat {
      let userInfo = switch (users.get(p)) {
        case (?info) info;
        case (null) initUser(p);
      };
      switch (AssocList.find<AssetId, Account>(userInfo.credits, assetId, Nat.equal)) {
        case (?acc) {
          acc.credit := credit;
          acc.credit - acc.lockedCredit;
        };
        case (null) {
          { var credit = credit; var lockedCredit = 0 }
          |> AssocList.replace<AssetId, Account>(userInfo.credits, assetId, Nat.equal, ?_)
          |> (userInfo.credits := _.0);
          metricAccountsAmount.add(1);
          credit;
        };
      };
    };

    public func deductCredit(p : Principal, assetId : AssetId, amount : Nat) : R.Result<(Nat, rollback : () -> ()), { #NoCredit }> {
      let ?user = users.get(p) else return #err(#NoCredit);
      let ?creditAcc = AssocList.find(user.credits, assetId, Nat.equal) else return #err(#NoCredit);
      if (creditAcc.credit < amount + creditAcc.lockedCredit) return #err(#NoCredit);
      // charge credit
      creditAcc.credit -= amount;
      #ok(
        creditAcc.credit,
        func() = creditAcc.credit += amount,
      );
    };

    private func getUserTrustedAccount_(userInfo : UserInfo) : ?Account = AssocList.find<AssetId, Account>(userInfo.credits, trustedAssetId, Nat.equal);

    public func placeAsk_(userInfo : UserInfo, askSourceAcc : Account, assetId : AssetId, assetInfo : AssetInfo, order : Order) {
      // update user info
      AssocList.replace<AssetId, Order>(userInfo.currentAsks, assetId, Nat.equal, ?order) |> (userInfo.currentAsks := _.0);
      askSourceAcc.lockedCredit += order.volume;
      // update asset info
      U.insertWithPriority<Order>(assetInfo.asks, order, func(x) = x.price > order.price) |> (assetInfo.asks := _);
      // update metrics
      assetInfo.metrics.asksAmount.add(1);
      assetInfo.metrics.totalAskVolume.add(order.volume);
    };

    private func placeBid_(userInfo : UserInfo, trustedAcc : Account, assetId : AssetId, assetInfo : AssetInfo, order : Order) {
      // update user info
      AssocList.replace<AssetId, Order>(userInfo.currentBids, assetId, Nat.equal, ?order) |> (userInfo.currentBids := _.0);
      trustedAcc.lockedCredit += getTotalPrice(order.volume, order.price);
      // update asset info
      U.insertWithPriority<Order>(assetInfo.bids, order, func(x) = x.price < order.price) |> (assetInfo.bids := _);
      // update metrics
      assetInfo.metrics.bidsAmount.add(1);
      assetInfo.metrics.totalBidVolume.add(order.volume);
    };

    public func cancelAsk_(user : Principal, userInfo : UserInfo, askSourceAcc : Account, assetId : AssetId, assetInfo : AssetInfo) : ?Order {
      // try to remove bid from user data
      AssocList.replace(userInfo.currentAsks, assetId, Nat.equal, null)
      |> (
        switch (_) {
          case (_, null) null;
          case (map, ?existingOrder) {
            // return deposit to user
            userInfo.currentAsks := map;
            askSourceAcc.lockedCredit -= existingOrder.volume;
            // remove ask from asset data
            let (upd, deleted) = U.listFindOneAndDelete<Order>(assetInfo.asks, func(order) = Principal.equal(order.user, user));
            assert deleted; // should always be true unless we have a bug with asset asks and user asks out of sync
            assetInfo.asks := upd;
            assetInfo.metrics.asksAmount.sub(1);
            assetInfo.metrics.totalAskVolume.sub(existingOrder.volume);
            ?existingOrder;
          };
        }
      );
    };

    private func cancelBid_(user : Principal, userInfo : UserInfo, userTrustedCredit : Account, assetId : AssetId, assetInfo : AssetInfo) : ?Order {
      // try to remove bid from user data
      AssocList.replace(userInfo.currentBids, assetId, Nat.equal, null)
      |> (
        switch (_) {
          case (_, null) null;
          case (map, ?existingBid) {
            // return deposit to user
            userInfo.currentBids := map;
            userTrustedCredit.lockedCredit -= getTotalPrice(existingBid.volume, existingBid.price);
            // remove bid from asset data
            let (upd, deleted) = U.listFindOneAndDelete<Order>(assetInfo.bids, func(bid) = Principal.equal(bid.user, user));
            assert deleted; // should always be true unless we have a bug with asset bids and user bids out of sync
            assetInfo.bids := upd;
            assetInfo.metrics.bidsAmount.sub(1);
            assetInfo.metrics.totalBidVolume.sub(existingBid.volume);
            ?existingBid;
          };
        }
      );
    };

    public func placeAsk(p : Principal, assetId : AssetId, volume : Nat, price : Float) : R.Result<(), PlaceOrderError> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);
      if (assetId == trustedAssetId or assetId >= Vec.size(assets)) return #err(#UnknownAsset);
      let assetInfo = Vec.get(assets, assetId);
      if (volume < settings.minAskVolume(assetId, assetInfo)) return #err(#TooLowOrder);
      let ?sourceAcc = AssocList.find<AssetId, Account>(userInfo.credits, assetId, Nat.equal) else return #err(#NoCredit);
      // cancel current ask of this user for this asset id if exists
      let oldOrder = cancelAsk_(p, userInfo, sourceAcc, assetId, assetInfo);
      if ((sourceAcc.credit - sourceAcc.lockedCredit) : Nat < volume) {
        // return old ask
        switch (oldOrder) {
          case (?b) placeAsk_(userInfo, sourceAcc, assetId, assetInfo, b);
          case (null) {};
        };
        return #err(#NoCredit);
      };
      // create and insert order
      let order : Order = {
        user = p;
        userInfoRef = userInfo;
        assetId = assetId;
        price = price;
        var volume = volume;
      };
      placeAsk_(userInfo, sourceAcc, assetId, assetInfo, order);
      #ok();
    };

    public func placeBid(p : Principal, assetId : AssetId, volume : Nat, price : Float) : R.Result<(), PlaceOrderError> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);
      if (assetId == trustedAssetId or assetId >= Vec.size(assets)) return #err(#UnknownAsset);
      let totalPrice = getTotalPrice(volume, price);
      if (totalPrice < MINIMUM_ORDER) return #err(#TooLowOrder);
      let assetInfo = Vec.get(assets, assetId);
      let ?trustedAcc = getUserTrustedAccount_(userInfo) else return #err(#NoCredit);
      // cancel current bid of this user for this asset id if exists
      let oldBid = cancelBid_(p, userInfo, trustedAcc, assetId, assetInfo);
      if ((trustedAcc.credit - trustedAcc.lockedCredit) : Nat < totalPrice) {
        // return old bid
        switch (oldBid) {
          case (?b) placeBid_(userInfo, trustedAcc, assetId, assetInfo, b);
          case (null) {};
        };
        return #err(#NoCredit);
      };
      // create and insert order
      let order : Order = {
        user = p;
        userInfoRef = userInfo;
        assetId = assetId;
        price = price;
        var volume = volume;
      };
      placeBid_(userInfo, trustedAcc, assetId, assetInfo, order);
      #ok();
    };

    public func cancelAsk(p : Principal, assetId : AssetId) : R.Result<Bool, OrderError> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);
      if (assetId == trustedAssetId or assetId >= Vec.size(assets)) return #err(#UnknownAsset);
      let ?sourceAcc = AssocList.find<AssetId, Account>(userInfo.credits, assetId, Nat.equal) else Prim.trap("Can never happen");
      cancelAsk_(p, userInfo, sourceAcc, assetId, Vec.get(assets, assetId)) |> #ok(not Option.isNull(_));
    };

    public func cancelBid(p : Principal, assetId : AssetId) : R.Result<Bool, OrderError> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);
      if (assetId == trustedAssetId or assetId >= Vec.size(assets)) return #err(#UnknownAsset);
      let ?trustedAcc = getUserTrustedAccount_(userInfo) else Prim.trap("Can never happen");
      cancelBid_(p, userInfo, trustedAcc, assetId, Vec.get(assets, assetId)) |> #ok(not Option.isNull(_));
    };

    // total instructions sent on last auction processing routine. Accumulated in case processing was splitted to few heartbeat calls
    public var lastBidProcessingInstructions : Nat64 = 0;
    // amount of chunks, used for processing all assets
    public var lastBidProcessingChunks : Nat8 = 0;

    // loops over asset ids, beginning from provided asset id, processes bids and sends rates to the ledger.
    // stops if we exceed instructions threshold and returns #nextIndex in this case
    private func processAssetsChunk(startIndex : Nat) : async* {
      #done;
      #nextIndex : Nat;
    } {
      let startInstructions = Prim.performanceCounter(0);
      // process bids
      let newSwapRates : Vec.Vector<(AssetId, Float)> = Vec.new();
      Vec.add(newSwapRates, (trustedAssetId, 1.0));
      var nextAssetId = 0;
      let inf : Float = 1 / 0; // +inf
      label l for (assetId in Iter.range(startIndex, Vec.size(assets) - 1)) {
        let assetStartInstructions = Prim.performanceCounter(0);
        nextAssetId := assetId + 1;
        if (assetId == trustedAssetId) continue l;
        let assetInfo = Vec.get(assets, assetId);

        var a = 0; // number of executed ask orders (at least partially executed)
        let ?(na, _) = assetInfo.asks else continue l;
        var asksTail = assetInfo.asks;
        var nextAsk = na;

        var b = 0; // number of executed buy orders (at least partially executed)
        let ?(nb, _) = assetInfo.bids else continue l;
        var bidsTail = assetInfo.bids;
        var nextBid = nb;

        var asksVolume = 0;
        var bidsVolume = 0;

        let (asksAmount, bidsAmount) = label L : (Nat, Nat) loop {
          let orig = (a, b);
          let inc_ask = asksVolume <= bidsVolume;
          let inc_bid = bidsVolume <= asksVolume;
          let prevAsk = nextAsk;
          if (inc_ask) {
            a += 1;
            let ?(na, at) = asksTail else break L orig;
            nextAsk := na;
            asksTail := at;
          };
          if (inc_bid) {
            b += 1;
            let ?(nb, bt) = bidsTail else {
              if (inc_ask) {
                // revert inc_ask, new one will not be fulfilled
                a -= 1;
                nextAsk := prevAsk;
              };
              break L orig;
            };
            nextBid := nb;
            bidsTail := bt;
          };
          if (nextAsk.price > nextBid.price) break L orig;
          if (inc_ask) asksVolume += nextAsk.volume;
          if (inc_bid) bidsVolume += nextBid.volume;
        };

        if (asksAmount == 0) continue l; // highest bid was lower than lowest ask
        // Note: asksAmount > 0 implies bidsAmount > 0

        let dealVolume = Nat.min(asksVolume, bidsVolume);

        let price : Float = switch (nextAsk.price == 0.0, nextBid.price == inf) {
          case (true, true) continue l; // market sell against market buy => no execution
          case (true, _) nextBid.price; // market sell against highest bid => use bid price
          case (_, true) nextAsk.price; // market buy against lowest ask => use ask price
          case (_) (nextAsk.price + nextBid.price) / 2; // limit sell against limit buy => use middle price
        };

        // process fulfilled asks
        var i = 0;
        var dealVolumeLeft = dealVolume;
        asksTail := assetInfo.asks;
        label b while (i < asksAmount) {
          let ?(order, next) = asksTail else Prim.trap("Can never happen: list shorter than before");
          let userInfo = order.userInfoRef;
          // update ask in user info and calculate real ask volume
          let volume = if (i + 1 == asksAmount and dealVolumeLeft != order.volume) {
            order.volume -= dealVolumeLeft;
            dealVolumeLeft;
          } else {
            AssocList.replace<AssetId, Order>(userInfo.currentAsks, assetId, Nat.equal, null) |> (userInfo.currentAsks := _.0);
            asksTail := next;
            assetInfo.metrics.asksAmount.sub(1);
            dealVolumeLeft -= order.volume;
            order.volume;
          };
          // remove price from deposit
          let ?sourceAcc = AssocList.find<AssetId, Account>(userInfo.credits, assetId, Nat.equal) else Prim.trap("Can never happen");
          sourceAcc.credit -= volume;
          // unlock locked deposit
          sourceAcc.lockedCredit -= volume;
          // credit user with trusted tokens
          switch (getUserTrustedAccount_(userInfo)) {
            case (?acc) acc.credit += getTotalPrice(volume, price);
            case (null) {
              {
                var credit = getTotalPrice(volume, price);
                var lockedCredit = 0;
              }
              |> AssocList.replace<AssetId, Account>(userInfo.credits, trustedAssetId, Nat.equal, ?_)
              |> (userInfo.credits := _.0);
              metricAccountsAmount.add(1);
            };
          };
          // update metrics
          assetInfo.metrics.totalAskVolume.sub(volume);
          // append to history
          userInfo.history := List.push((Prim.time(), sessionsCounter, #ask, assetId, volume, price), userInfo.history);
          i += 1;
        };
        assetInfo.asks := asksTail;

        // process fulfilled bids
        i := 0;
        dealVolumeLeft := dealVolume;
        bidsTail := assetInfo.bids;
        label b while (i < bidsAmount) {
          let ?(order, next) = bidsTail else Prim.trap("Can never happen: list shorter than before");
          let userInfo = order.userInfoRef;
          // update bid in user info and calculate real bid volume
          let volume = if (i + 1 == bidsAmount and dealVolumeLeft != order.volume) {
            order.volume -= dealVolumeLeft;
            dealVolumeLeft;
          } else {
            AssocList.replace<AssetId, Order>(userInfo.currentBids, assetId, Nat.equal, null) |> (userInfo.currentBids := _.0);
            bidsTail := next;
            assetInfo.metrics.bidsAmount.sub(1);
            dealVolumeLeft -= order.volume;
            order.volume;
          };
          // remove price from deposit
          let ?trustedAcc = getUserTrustedAccount_(userInfo) else Prim.trap("Can never happen");
          trustedAcc.credit -= getTotalPrice(volume, price);
          // unlock locked deposit (note that it uses bid price)
          trustedAcc.lockedCredit -= getTotalPrice(volume, order.price);
          // credit user with tokens
          switch (AssocList.find<AssetId, Account>(userInfo.credits, assetId, Nat.equal)) {
            case (?acc) acc.credit += volume;
            case (null) {
              { var credit = volume; var lockedCredit = 0 }
              |> AssocList.replace<AssetId, Account>(userInfo.credits, assetId, Nat.equal, ?_)
              |> (userInfo.credits := _.0);
              metricAccountsAmount.add(1);
            };
          };
          // update metrics
          assetInfo.metrics.totalBidVolume.sub(volume);
          // append to history
          userInfo.history := List.push((Prim.time(), sessionsCounter, #bid, assetId, volume, price), userInfo.history);
          i += 1;
        };
        assetInfo.bids := bidsTail;

        assetInfo.lastSwapRate := price;
        // append to asset history
        history := List.push((Prim.time(), sessionsCounter, assetId, dealVolume, price), history);

        let curPerfCounter = Prim.performanceCounter(0);
        assetInfo.metrics.lastProcessingInstructions.set(Nat64.toNat(curPerfCounter - assetStartInstructions));
        if (curPerfCounter - startInstructions > BID_PROCESSING_INSTRUCTIONS_THRESHOLD) break l;
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

    var nextAssetIdToProcess : Nat = 0;

    public func onTimer() : async () {
      if (nextAssetIdToProcess == 0) {
        switch (hooks.preAuction) {
          case (?hook) await* hook();
          case (_) {};
        };
      };
      switch (await* processAssetsChunk(nextAssetIdToProcess)) {
        case (#done) {
          switch (hooks.postAuction) {
            case (?hook) await* hook();
            case (_) {};
          };
          sessionsCounter += 1;
          nextAssetIdToProcess := 0;
        };
        case (#nextIndex next) {
          if (next == nextAssetIdToProcess) {
            Prim.trap("Can never happen: not a single asset processed");
          };
          nextAssetIdToProcess := next;
          ignore Timer.setTimer<system>(#seconds(1), onTimer);
        };
      };
    };

    let AUCTION_INTERVAL_SECONDS : Nat64 = 86_400; // a day
    public func remainingTime() : Nat = Nat64.toNat(AUCTION_INTERVAL_SECONDS - (Prim.time() / 1_000_000_000) % AUCTION_INTERVAL_SECONDS);

    // run daily at 12:00 a.m. UTC
    ignore (
      func() : async () {
        ignore Timer.recurringTimer<system>(#seconds(Nat64.toNat(AUCTION_INTERVAL_SECONDS)), onTimer);
        await onTimer();
      }
    ) |> Timer.setTimer<system>(#seconds(remainingTime()), _);

    public func share() : StableData = {
      sessionsCounter = sessionsCounter;
      assets = Vec.map<AssetInfo, StableAssetInfo>(
        assets,
        func(x) = {
          asks = x.asks;
          bids = x.bids;
          lastSwapRate = x.lastSwapRate;
        },
      );
      users = users.share();
      history = history;
    };

    public func unshare(data : StableData) {
      sessionsCounter := data.sessionsCounter;
      var i = 0;
      assets := Vec.map<StableAssetInfo, AssetInfo>(
        data.assets,
        func(x) {
          let r = {
            var asks = x.asks;
            var bids = x.bids;
            var lastSwapRate = x.lastSwapRate;
            metrics = initAssetMetrics(i);
          };
          i += 1;
          r;
        },
      );
      users.unshare(data.users);
      history := data.history;
    };

  };
};
