import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Prim "mo:prim";
import Timer "mo:base/Timer";
import Bool "mo:base/Bool";

module Scheduler {

  // will handle a recurrent timer, aligned to timestamp, e.g. if you setup daily interval,
  // it will run at each midnight no matter when exactly start function was called.
  // If you want to run it at a different time, use "bias" property
  public class Scheduler(intervalSeconds : Nat64, biasSeconds : Nat64, handler : (counter : Nat) -> async* ()) {

    var timerId_ : ?Nat = null;
    public func timerId() : ?Nat = timerId_;

    public func isExecutingHandler() : Bool = executionLock;

    private var immediateCallRunning_ : Bool = false;
    public func isRunning() : Bool = not Option.isNull(timerId_) or immediateCallRunning_;

    public func nextExecutionAt() : Nat64 = 1_000_000_000 * (intervalSeconds * (1 + (Prim.time() - biasSeconds * 1_000_000_000) / (intervalSeconds * 1_000_000_000)) + biasSeconds);

    private var executionLock : Bool = false;
    private var executionCounter : Nat = 0;
    private func handlerInternal() : async () {
      assert not executionLock;
      executionLock := true;
      try {
        await* handler(executionCounter);
      } finally {
        executionLock := false;
        executionCounter += 1;
      };
    };

    public func startImmediately<system>() : async* () {
      if (isRunning()) {
        stop();
      };
      immediateCallRunning_ := true;
      executionCounter := 0;
      try {
        await handlerInternal();
      } catch (_) {};
      immediateCallRunning_ := false;
      if (not isRunning()) {
        start<system>();
      };
    };

    public func start<system>() {
      if (isRunning()) {
        return;
      };
      executionCounter := 0;
      timerId_ := (
        func() : async () {
          timerId_ := ?Timer.recurringTimer<system>(#seconds(Nat64.toNat(intervalSeconds)), handlerInternal);
          await handlerInternal();
        }
      ) |> ?Timer.setTimer<system>(#seconds(Nat64.toNat(intervalSeconds - (Prim.time() / 1_000_000_000 - biasSeconds) % intervalSeconds)), _);
    };

    public func stop() {
      switch (timerId_) {
        case (?t) {
          timerId_ := null;
          Timer.cancelTimer(t);
        };
        case (_) {};
      };
    };

  };

};
