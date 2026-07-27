import Queue "mo:core/Queue";

import T "./types";

module {

  // instance of this class should be declared as transient. It does not contain any data that must be stored in stable data
  public class AuctionRuntime(
    _auction : T.AuctionNew,
    _settings : {
      minAskVolume : (T.AssetId, T.Asset) -> Int;
      performanceCounter : Nat32 -> Nat64;
    },
  ) {

    // This field does not survive upgrades, since we (currently) send them straight away
    public var stagedPushNotifications : Queue.Queue<(user : Principal, notification : T.PushNotification)> = Queue.empty();

    public func stagePushNotification(user : Principal, notification : T.PushNotification) {
      stagedPushNotifications.pushBack((user, notification));
    };

  };
};
