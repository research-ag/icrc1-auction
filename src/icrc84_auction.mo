import Array "mo:base/Array";
import R "mo:base/Result";

import Auction "auction/src";
import T "auction/src/types";

// auction API response types, where AssetId has type Principal instead of Nat
// and conversion functions for them
module Icrc84Auction {

  type InternalCancelOrderError = {
    #UnknownOrder;
  };
  type InternalPlaceOrderError = {
    #ConflictingOrder : ({ #ask; #bid }, ?T.OrderId);
    #NoCredit;
    #TooLowOrder;
    #UnknownAsset;
    #PriceDigitsOverflow : { maxDigits : Nat };
    #VolumeStepViolated : { baseVolumeStep : Nat };
  };

  public type CancellationResult = (T.OrderId, assetId : Principal, orderType : Auction.OrderType, volume : Nat, price : Float);

  public type ManageOrdersError = {
    #AccountRevisionMismatch;
    #UnknownPrincipal;
    #cancellation : {
      index : Nat;
      error : InternalCancelOrderError or { #UnknownAsset };
    };
    #placement : { index : Nat; error : InternalPlaceOrderError };
  };
  public type CancelOrderError = InternalCancelOrderError or {
    #AccountRevisionMismatch;
    #UnknownPrincipal;
  };
  public type PlaceOrderError = InternalPlaceOrderError or {
    #AccountRevisionMismatch;
    #UnknownPrincipal;
  };
  public type ReplaceOrderError = CancelOrderError or PlaceOrderError;

  type UpperResult<Ok, Err> = { #Ok : Ok; #Err : Err };

  public func mapCancelOrderResult(res : R.Result<Auction.CancellationResult, Auction.CancelOrderError>, getToken : (T.AssetId) -> Principal) : UpperResult<CancellationResult, CancelOrderError> {
    switch (res) {
      case (#ok(oid, aid, orderType, volume, price)) #Ok(oid, getToken(aid), orderType, volume, price);
      case (#err err) #Err(err);
    };
  };

  public func mapManageOrdersResult(res : R.Result<([Auction.CancellationResult], [Auction.PlaceOrderResult]), Auction.ManageOrdersError>, getToken : (T.AssetId) -> Principal) : UpperResult<([CancellationResult], [Auction.PlaceOrderResult]), ManageOrdersError> {
    switch (res) {
      case (#ok(cancellations, placements)) #Ok(
        Array.map<Auction.CancellationResult, CancellationResult>(cancellations, func(oid, aid, orderType, volume, price) = (oid, getToken(aid), orderType, volume, price)),
        placements,
      );
      case (#err err) #Err(err);
    };
  };

};
