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

  public func mapPlaceOrderResult(res : R.Result<T.OrderId, Auction.PlaceOrderError>, getToken : (T.AssetId) -> Principal) : UpperResult<T.OrderId, PlaceOrderError> {
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

  public func mapReplaceOrderResult(res : R.Result<T.OrderId, Auction.ReplaceOrderError>, getToken : (T.AssetId) -> Principal) : UpperResult<T.OrderId, ReplaceOrderError> {
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

  public func mapCancelOrderResult(res : R.Result<(), Auction.CancelOrderError>, getToken : (T.AssetId) -> Principal) : UpperResult<(), CancelOrderError> {
    switch (res) {
      case (#ok x) #Ok(x);
      case (#err err) #Err(
        switch (err) {
          case (#UnknownOrder x) #UnknownOrder(x);
          case (#UnknownPrincipal x) #UnknownPrincipal(x);
          case (#SessionNumberMismatch aid) #SessionNumberMismatch(getToken(aid));
        }
      );
    };
  };

  public func mapManageOrdersResult(res : R.Result<[Auction.OrderId], Auction.ManageOrdersError>, getToken : (T.AssetId) -> Principal) : UpperResult<[Auction.OrderId], ManageOrdersError> {
    switch (res) {
      case (#ok x) #Ok(x);
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
