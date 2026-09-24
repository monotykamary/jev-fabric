import Base
import ../Core.bend as Core

# These are implementation contracts, not user-authored LAWS.bend requirements.
# Foreign OS effects, floating-point operations, and HTTP are outside these proofs.
law exhausted_never_reserves:
  for used: Nat
  for tokens: Nat
  for limit: Nat
  {Core.reserve(Core.Budget{0n, used, tokens, limit}) == None{} : Maybe<&2, Core.Budget>}

def exhausted_never_reserves(used, tokens, limit):
  {==}

law cancelled_is_terminal:
  for result: Core.State
  {Core.settle(Core.Cancelled{}, result) == Core.Cancelled{} : Core.State}

def cancelled_is_terminal(result):
  {==}

law completed_is_terminal:
  for result: Core.State
  {Core.settle(Core.Completed{}, result) == Core.Completed{} : Core.State}

def completed_is_terminal(result):
  {==}

law unknown_requires_inspection:
  {Core.after(Core.Unknown{}) == Core.Inspect{} : Core.Next}

def unknown_requires_inspection():
  {==}

law dispatch_requires_verification:
  {Core.after(Core.Executed{}) == Core.Verify{} : Core.Next}

def dispatch_requires_verification():
  {==}
