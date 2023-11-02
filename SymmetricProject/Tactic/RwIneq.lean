import Mathlib.Data.Complex.Exponential

open Lean Meta Elab Term Tactic

/-- Returns a version of `target` where any occurence of `old` as a function argument has
been replaced by `new`. Comparison with `old` is up to defEq. -/
def Lean.Expr.subst (target old new : Expr) : MetaM Expr := do
  if ← isDefEq target old then
    return new
  else
    match target with
    | Expr.app fn arg    => return (Expr.app (← fn.subst old new) (← arg.subst old new))
    | _                  => return target

/-- Given expressions `orig : r a b` and `subst : s x y` for some relations
`r` and `s`, build the expression `r b c` where `c` is obtained from `b` by replacing
any occurence of `x` in a function application argument by `y`. -/
def Lean.Expr.substInRel (orig subst : Expr) : MetaM (Option Expr) := do
  let some (relo, _lo, ro) := (← getCalcRelation? orig) | return none
  let some (_rels, ls, rs) := (← getCalcRelation? subst) | return none
  return some (← mkAppM' relo #[ro, (← ro.subst ls rs)])

/-- Given expressions `orig : r a b` and `subst : s x y` for some relations
`r` and `s`, build the expression `r a c` where `c` is obtained from `a` by replacing
any occurence of `x` in a function application argument by `y`. -/
def Lean.Expr.substInRel' (orig subst : Expr) : MetaM (Option Expr) := do
  let some (relo, lo, _ro) := (← getCalcRelation? orig) | return none
  let some (_rels, ls, rs) := (← getCalcRelation? subst) | return none
  -- dbg_trace "lo: {← ppExpr lo}\nls: {← ppExpr ls}\nrs: {← ppExpr rs}"
  return some (← mkAppM' relo #[lo, (← lo.subst ls rs)])


/-- Given expressions `orig : r a b` and `subst : s x y` for some relations
`r` and `s`, build the expression `r c a` where `c` is obtained from `a` by replacing
any occurence of `y` in a function application argument by `x`. -/
def Lean.Expr.substInRelRev (orig subst : Expr) : MetaM (Option Expr) := do
  let some (relo, lo, _ro) := (← getCalcRelation? orig) | return none
  let some (_rels, ls, rs) := (← getCalcRelation? subst) | return none
  return some (← mkAppM' relo #[(← lo.subst rs ls), lo])


def gcongrDefaultDischarger (g : MVarId) : MetaM PUnit :=Term.TermElabM.run' do
  let [] ← Tactic.run g <| evalTactic (Unhygienic.run `(tactic| gcongr_discharger)) | failure

/-- Rewrite in the relation assumption `h : r a b` using `subst : s x y` to produce `h : r a c`
where `c` is obtained from `b` by replacing any occurence of `x` in a function application argument
by `y`. This new relation `h` is proven from `trans h h'` where `h' : r b c` is proven by `gcongr`
using the list of given identifiers for newly introduced variables.
Returns the list of new goals. -/
def Lean.MVarId.rwIneq (g : MVarId) (h : Name) (substPrf : Expr) (rev : Bool)
    (names : List (TSyntax ``binderIdent)) : MetaM (List MVarId) := do
  g.withContext do
  let subst ← inferType substPrf
  let decl ← (← getLCtx).findFromUserName? h
  let substFun := if rev then Lean.Expr.substInRelRev else Lean.Expr.substInRel
  let some newIneq ← substFun decl.type subst
    | throwError "Could not create the new relation."
  let g ← if substPrf.isFVar then pure g else do
    let (_, g) ← g.note (← mkFreshUserName `providedRel) substPrf
    pure g
  g.withContext do
  let mvar ← mkFreshExprMVar newIneq
  let (success, _, newGoals) ← mvar.mvarId!.gcongr none names gcongrDefaultDischarger
  if success then
    let g ← g.clear decl.fvarId
    let transArgs := if rev then #[mvar, .fvar decl.fvarId] else #[.fvar decl.fvarId, mvar]
    let (_, newGoal) ← g.note decl.userName (← mkAppM `Trans.trans transArgs)
    return newGoal::newGoals.toList
  else
    throwError "The `gcongr` tactic called by `rw_ineq` failed."

deriving instance DecidableEq for MVarId

def Lean.MVarId.rwIneqTgt (g : MVarId) (substPrf : Expr) (rev : Bool)
    (names : List (TSyntax ``binderIdent)) : MetaM (List MVarId) := do
  g.withContext do
  let subst ← inferType substPrf
  let tgt := (← g.getType).consumeMData
  let some (_, _, tgtRHS) ← getCalcRelation? tgt
    | throwError "The current goal is not a relation."
  let substFun := if rev then Lean.Expr.substInRelRev else Lean.Expr.substInRel'
  let some newIneq ← substFun tgt subst
    | throwError "Could not create the new relation."
  -- dbg_trace "New ineq: {← ppExpr newIneq}"
  let (providedRelFVarId?, g) ← if substPrf.isFVar then pure (none, g) else do
    let intermediateName ← mkFreshUserName `providedRel
    let (providedRelFVarId, g) ← g.note intermediateName substPrf
    pure (some providedRelFVarId, g)
  g.withContext do
  let newIneqPrf ← mkFreshExprMVar newIneq
  let (success, _, newGCongrGoals) ← newIneqPrf.mvarId!.gcongr none names gcongrDefaultDischarger
  let newGCongrGoals := newGCongrGoals.toList
  if success then
    let relExpr : Expr := mkAppN tgt.getAppFn tgt.getAppArgs[:2]
    let newGoal ← if let some fvarId := providedRelFVarId? then g.clear fvarId
      else pure g
    let transExpr ← mkAppOptM `Trans.trans #[none, none, none, none, relExpr, none,
      none, none, none, tgtRHS, newIneqPrf]
    let newerGoals ← newGoal.apply transExpr
    dbg_trace "newerGoals: {newerGoals.map (·.name)}"
    dbg_trace "newGCongrGoals: {newGCongrGoals.map (·.name)}"
    let mut goals : List MVarId := []
    for goal in (newerGoals ++ newGCongrGoals).dedup do
      try
        dbg_trace s!"Will try linarith on {← ppExpr <| ← goal.getType} with only {← ppExpr <| ← inferType substPrf}"
        goal.withContext do
          Linarith.runLinarith  {preprocessors := Linarith.defaultPreprocessors} none  goal [substPrf]
        dbg_trace "Success!"
      catch e=> do
        dbg_trace "Failed on {goal.name}: {← e.toMessageData.format}."
        goals := goal::goals
    dbg_trace "Remaining goals"
    for g in goals do
      dbg_trace (g.name, (← g.isAssigned))
    return goals


  else
    throwError "The `gcongr` tactic called by `rw_ineq` failed."


open Lean Parser Tactic

/-- `rw_ineq e at h` rewrite in the relation assumption `h : r a b` using `e : s x y` to replace `h`
with `r a c` where `c` is obtained from `b` by replacing any occurence of `x` in a function
application argument by `y`. This may generate new goals including new objects that can
be named using the `with` clause.

```
open Real

example (x y z w u : ℝ) (bound : x * exp y ≤ z + exp w) (h : w ≤ u) :  x * exp y ≤ z + exp u := by
  rw_ineq h at bound
  exact bound
```
-/
elab tok:"rw_ineq" rules:rwRuleSeq "at " h:ident withArg:((" with " (colGt binderIdent)+)?) : tactic =>
  withMainContext do
  withRWRulesSeq tok rules fun symm term => do
    let mainGoal ← getMainGoal
    mainGoal.withContext do
    let substPrf ← Lean.Elab.Term.elabTerm term none
    let names := (withArg.raw[1].getArgs.map TSyntax.mk).toList
    replaceMainGoal (← mainGoal.rwIneq h.getId substPrf symm names)

elab tok:"rw_ineq_tgt" rules:rwRuleSeq withArg:((" with " (colGt binderIdent)+)?) : tactic =>
  withMainContext do
  withRWRulesSeq tok rules fun symm term => do
    let mainGoal ← getMainGoal
    mainGoal.withContext do
    let substPrf ← Lean.Elab.Term.elabTerm term none
    let names := (withArg.raw[1].getArgs.map TSyntax.mk).toList
    let goals ← mainGoal.rwIneqTgt substPrf symm names
    dbg_trace "replaceMainGoal {goals.map (·.name)}"
    replaceMainGoal goals


/-- `rwa_ineq e at h` rewrite in the relation assumption `h : r a b` using `e : s x y` to replace `h`
with `r a c` where `c` is obtained from `b` by replacing any occurence of `x` in a function
application argument by `y`. Then tries to close the main goal using `assumption`.
This may generate new goals including new objects that can be named using the `with` clause.

```
open Real

example (x y z w u : ℝ) (bound : x * exp y ≤ z + exp w) (h : w ≤ u) :  x * exp y ≤ z + exp u := by
  rwa_ineq h at bound
```
-/
elab tok:"rwa_ineq" rules:rwRuleSeq "at " h:ident withArg:((" with " (colGt binderIdent)+)?) : tactic =>
  withMainContext do
  withRWRulesSeq tok rules fun symm term => do
    let mainGoal ← getMainGoal
    mainGoal.withContext do
    let substPrf ← Lean.Elab.Term.elabTerm term none
    let names := (withArg.raw[1].getArgs.map TSyntax.mk).toList
    replaceMainGoal (← mainGoal.rwIneq h.getId substPrf symm names)
  (← getMainGoal).assumption

open Real

/- example (x y z w u : ℝ) (bound : x * exp y ≤ z + 2*exp w) (h : w ≤ u) :
    x * exp y ≤ z + 2*exp u := by
  rw_ineq [h] at bound
  exact bound

example (x y z w u : ℝ) (bound : x * exp y < z + 2*exp w) (h : w < u) :
    x * exp y < z + 2*exp u := by
  rwa_ineq [h] at bound

-- Test where a side condition is not automatically discharged.
example (x y z w u : ℝ) (bound : x * exp y < z + x^2*exp w) (h : w < u) (hx : 2*x > 2) :
    x * exp y < z + x^2*exp u := by
  rwa_ineq [h] at bound
  apply pow_pos
  linarith

example {a b c d : ℝ} (bound : a + b ≤ c + d) (h : c ≤ 2) (k : 1 ≤ a) : 1 + b ≤ 2 + d := by
  rwa_ineq [h, ← k] at bound

example {a b : ℕ} (h: a ≤ 2 * b) : a ≤ 3 * b  := by
  rwa_ineq [show 2 ≤ 3 by norm_num] at h

example {a b : ℝ} (hb : 0 < b) (h: a ≤ 2 * b) : a ≤ 3 * b  := by
  have test : (2 : ℝ) ≤ 3 := by norm_num
  rwa_ineq [test] at h -/
--set_option pp.explicit true


example {a c : ℕ} (hc : a < c) : 2 * a ≤ 3 * c  := by

  --set_option trace.linarith true in
  --have : a ≤ c := by linarith only [hc]
  --have h : 2 ≤ 3 := by norm_num
  rw_ineq_tgt [show 2 ≤ 3 by norm_num]
  -- set_option trace.linarith.detail true in
  -- set_option trace.linarith true in
  set_option trace.linarith true in
  rw_ineq_tgt [hc]

  --try rfl
