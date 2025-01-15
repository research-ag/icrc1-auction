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
    #SessionNumberMismatch : Principal;
    #UnknownPrincipal;
    #cancellation : {
      index : Nat;
      error : InternalCancelOrderError or { #UnknownAsset };
    };
    #placement : { index : Nat; error : InternalPlaceOrderError };
  };
  public type CancelOrderError = InternalCancelOrderError or {
    #SessionNumberMismatch : Principal;
    #UnknownPrincipal;
  };
  public type PlaceOrderError = InternalPlaceOrderError or {
    #SessionNumberMismatch : Principal;
    #UnknownPrincipal;
  };
  public type ReplaceOrderError = CancelOrderError or PlaceOrderError;

  type UpperResult<Ok, Err> = { #Ok : Ok; #Err : Err };

  public func mapPlaceOrderResult(res : R.Result<Auction.PlaceOrderResult, Auction.PlaceOrderError>, getToken : (T.AssetId) -> Principal) : UpperResult<Auction.PlaceOrderResult, PlaceOrderError> {
    switch (res) {
      case (#ok x) #Ok(x);
      case (#err err) #Err(
        switch (err) {
          case (#ConflictingOrder x) #ConflictingOrder(x);
          case (#NoCredit x) #NoCredit(x);
          case (#TooLowOrder x) #TooLowOrder(x);
          case (#UnknownAsset x) #UnknownAsset(x);
          case (#PriceDigitsOverflow x) #PriceDigitsOverflow(x);
          case (#VolumeStepViolated x) #VolumeStepViolated(x);
          case (#UnknownPrincipal x) #UnknownPrincipal(x);
          case (#SessionNumberMismatch aid) #SessionNumberMismatch(getToken(aid));
        }
      );
    };
  };

  public func mapReplaceOrderResult(res : R.Result<Auction.PlaceOrderResult, Auction.ReplaceOrderError>, getToken : (T.AssetId) -> Principal) : UpperResult<Auction.PlaceOrderResult, ReplaceOrderError> {
    switch (res) {
      case (#ok x) #Ok(x);
      case (#err err) #Err(
        switch (err) {
          case (#ConflictingOrder x) #ConflictingOrder(x);
          case (#NoCredit x) #NoCredit(x);
          case (#TooLowOrder x) #TooLowOrder(x);
          case (#UnknownAsset x) #UnknownAsset(x);
          case (#PriceDigitsOverflow x) #PriceDigitsOverflow(x);
          case (#VolumeStepViolated x) #VolumeStepViolated(x);
          case (#UnknownOrder x) #UnknownOrder(x);
          case (#UnknownPrincipal x) #UnknownPrincipal(x);
          case (#SessionNumberMismatch aid) #SessionNumberMismatch(getToken(aid));
        }
      );
    };
  };

  public func mapCancelOrderResult(res : R.Result<Auction.CancellationResult, Auction.CancelOrderError>, getToken : (T.AssetId) -> Principal) : UpperResult<CancellationResult, CancelOrderError> {
    switch (res) {
      case (#ok(oid, aid, orderType, volume, price)) #Ok(oid, getToken(aid), orderType, volume, price);
      case (#err err) #Err(
        switch (err) {
          case (#UnknownOrder x) #UnknownOrder(x);
          case (#UnknownPrincipal x) #UnknownPrincipal(x);
          case (#SessionNumberMismatch aid) #SessionNumberMismatch(getToken(aid));
        }
      );
    };
  };

  public func mapManageOrdersResult(res : R.Result<([Auction.CancellationResult], [Auction.PlaceOrderResult]), Auction.ManageOrdersError>, getToken : (T.AssetId) -> Principal) : UpperResult<([CancellationResult], [Auction.PlaceOrderResult]), ManageOrdersError> {
    switch (res) {
      case (#ok(cancellations, placements)) #Ok(
        Array.map<Auction.CancellationResult, CancellationResult>(cancellations, func(oid, aid, orderType, volume, price) = (oid, getToken(aid), orderType, volume, price)),
        placements,
      );
      case (#err err) #Err(
        switch (err) {
          case (#UnknownPrincipal x) #UnknownPrincipal(x);
          case (#SessionNumberMismatch aid) #SessionNumberMismatch(getToken(aid));
          case (#cancellation { index; error }) #cancellation({ index; error });
          case (#placement { index; error }) #placement({
            index;
            error = switch (error) {
              case (#ConflictingOrder x) #ConflictingOrder(x);
              case (#NoCredit x) #NoCredit(x);
              case (#TooLowOrder x) #TooLowOrder(x);
              case (#UnknownAsset x) #UnknownAsset(x);
              case (#PriceDigitsOverflow x) #PriceDigitsOverflow(x);
              case (#VolumeStepViolated x) #VolumeStepViolated(x);
            };
          });
        }
      );
    };
  };

};
