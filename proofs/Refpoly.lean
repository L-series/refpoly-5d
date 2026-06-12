-- Root module for the Refpoly formalization.
-- See PROOF_PLAN.md for the full list of theorems and their provenance.
--
-- Reading order (matches PROOF_PLAN.md parts):
--   Basic          Part 0: lattice polytopes, polar duality, bipolar theorem
--   Finiteness     Part 1: Hensley/Lagarias–Ziegler finiteness (2 axiomatized inputs)
--   MaxMin         Parts 2–3: maximal/minimal polytopes, duality, minimal IP sets
--   Minimal        Part 4: simplices and barycentric weight systems
--   WeightSystem   Part 5: weight systems, Δ_q, IP property, CWS
--   PyramidLemma   Part 6: d ≤ 4 vs d = 5 (counterexample fully proved)
--   Algorithm      Part 7: the [SS18] enumeration — completeness & termination
--   Sylvester      Part 8: the Sylvester sequence and the degree bound 3263442
--   Classification Part 9: every reflexive polytope is reached by the pipeline
import Refpoly.Basic
import Refpoly.Finiteness
import Refpoly.MaxMin
import Refpoly.Minimal
import Refpoly.WeightSystem
import Refpoly.PyramidLemma
import Refpoly.Algorithm
import Refpoly.Sylvester
import Refpoly.Classification
