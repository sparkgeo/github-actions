---------------------------- MODULE IdempotentRetry ----------------------------
(***************************************************************************)
(* Retry with an idempotency key (issue #130). A client sends a request   *)
(* for each key and may retry it up to MaxRetries times, because the      *)
(* network can drop or delay any copy. Copies arrive in any order. The    *)
(* server applies a request only if it has not seen the key. The safety   *)
(* claim is AppliedAtMostOnce: no interleaving applies a key twice.       *)
(* Maps to: internal/queue/worker.go (verify.yml `covers`).               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

\* The @type comments are for Apalache (use-apalache); TLC ignores them.
CONSTANTS
  \* @type: Set(Str);
  Keys,
  \* @type: Int;
  MaxRetries

VARIABLES
  \* @type: Set(<<Str, Int>>);
  inflight,
  \* @type: Str -> Int;
  applied,
  \* @type: Set(Str);
  seen,
  \* @type: Str -> Int;
  attempts

vars == <<inflight, applied, seen, attempts>>

TypeOK ==
  /\ inflight \subseteq (Keys \X (0..MaxRetries))
  /\ applied \in [Keys -> 0..(MaxRetries + 1)]
  /\ seen \subseteq Keys
  /\ attempts \in [Keys -> 0..MaxRetries]

Init ==
  /\ inflight = {}
  /\ applied = [k \in Keys |-> 0]
  /\ seen = {}
  /\ attempts = [k \in Keys |-> 0]

\* The client sends (or re-sends) the request for key k.
Send(k) ==
  /\ attempts[k] < MaxRetries
  /\ inflight' = inflight \cup {<<k, attempts[k]>>}
  /\ attempts' = [attempts EXCEPT ![k] = @ + 1]
  /\ UNCHANGED <<applied, seen>>

\* One copy arrives; the server deduplicates on the key.
Deliver(m) ==
  /\ inflight' = inflight \ {m}
  /\ IF m[1] \in seen
       THEN UNCHANGED <<applied, seen>>
       ELSE /\ applied' = [applied EXCEPT ![m[1]] = @ + 1]
            /\ seen' = seen \cup {m[1]}
  /\ UNCHANGED attempts

\* The network loses a copy.
Drop(m) ==
  /\ inflight' = inflight \ {m}
  /\ UNCHANGED <<applied, seen, attempts>>

\* Every retry spent and nothing in flight: the run is over, not deadlocked.
Done ==
  /\ inflight = {}
  /\ \A k \in Keys : attempts[k] = MaxRetries
  /\ UNCHANGED vars

\* Named so a TLC counterexample trace says which step happened.
Retry == \E k \in Keys : Send(k)
Receive == \E m \in inflight : Deliver(m)
Lose == \E m \in inflight : Drop(m)

Next == Retry \/ Receive \/ Lose \/ Done

Spec == Init /\ [][Next]_vars

AppliedAtMostOnce == \A k \in Keys : applied[k] <= 1
=============================================================================
