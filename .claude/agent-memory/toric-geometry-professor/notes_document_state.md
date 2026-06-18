---
name: notes-document-state
description: State of docs/theory_notes.tex — which sections are written vs placeholder.
metadata:
  type: project
---

The running LaTeX lecture notes live at `latex/notes/theory_notes.tex` (amsart
class, standard theorem environments). Created 2026-06-06. (User explicitly chose
`latex/notes/` over `docs/` for the file location.)

There is also a SECOND standalone document `latex/notes/ks_classification.tex`
(created 2026-06-06, same amsart preamble/theorem envs), a self-contained
chapter on the Kreuzer--Skarke classification programme: finiteness
(Hensley/Lagarias--Ziegler), subpolytope->maximal reduction, max/min polar
duality, decomposition of minimal polytopes into simplices/products (IP
property, circuits), and weight systems + combined weight systems, ending with
the full KS pipeline and a refpoly-5d tie-in. References include the two KS
papers (1998 hep-th/9805190, 2000 hep-th/0002240), PALP (math/0204356), Batyrev,
Hensley, Lagarias--Ziegler. As of 2026-06-06 it ALSO has a long
"The enumeration algorithm and its PALP implementation" section (Section
labeled sec:algo) cross-referencing the actual PALP submodule source in
`PALP/`: WS bounds (Rec_IpWeights/MakeIpWeights, wmax=d/(N-i+1), sorted, gcd=1),
IP/reflexivity test (IfIpWWrite->IP_Check, facet test E.e[i].c==1), the dual Rgc
enumeration (RecConstructRgcWeights/WsIpCheck/LastPointForbidden, RgcClassData
with r2/allow11), CWS validity + the CWS struct in Global.h, embeddings via
W_TO_CWS/RW_TO_CWS (overlap u, paddings Nf/Nr/Nb), Select_n_of_W/next_n,
Make_CWS_Points (Coord.c), Make_Dual_Poly, normal form Make_Poly_NF/
GLZ_Make_Trian_NF/GL_W_to_GLZ/Make_Poly_Sym_NF (Polynf.c), class.c/Subpoly.c/
Subdb.c dedup via NF_List, and constants POLY_Dmax=6, AMBI_Dmax=30, W_Nmax=6,
WDIM=800000. Compiles clean with pdflatex (run twice; now 19 pages as of
2026-06-06 after the Q1-Q4 additions below).
README build section lists both .tex files. Each document is its OWN standalone
file (own \documentclass + \maketitle); there is no master/include file.

**2026-06-06 additions to ks_classification.tex (Section sec:algo):**
- Q2 IP criterion: Lemma `lem:ipcrit` + proof (origin interior to simplex iff
  the unique-up-to-scale affine dependence sum w_i v_i=0 has all w_i>0;
  barycentric-coords argument), eq `eq:ipcrit` is now equation (7.1). Plus
  Remark `rmk:ipcrit`. Placed at start of sec:algo-singleWS.
- Q1 finiteness of WS search space: Prop `prop:wsfinite` (two-layer
  finiteness: finite degrees via IP+Hensley bound, finite box per degree via
  w_i<=d/(N-i+1)) + Remark `rmk:boundmatch` mapping theory bound EXACTLY to
  MakeIpWeights outer loop (W.d in [from_d,to_d], w[N-1] from d/2 to d/N) and
  Rec_IpWeights inner recursion.
- Q3 CWS type enumeration: new subsec `sec:algo-cwstypes`. Prop `prop:cwsenum`
  (types = solutions of sum(N_j)-u_tot=d, eq `eq:cwsdimcount`), Example
  `ex:cws4types` (the 9 hard-coded d=4 types from Make_34_CWS: 5, 4uu4, 3u4,
  3x3, 2x4, 3u3x2, 3x2x2, 3u3u3, 2x2x2x2), Theorem `thm:cws5types` (explicit
  d=5 table by r=1..5 with primitive-type bullet list), Remarks `rmk:cws5`
  (d>4 uses generic Make_IP_CWS via -c5 -n# files -t overlaps, NOT hard-coded)
  and `rmk:cws5caveat`.
- Q4 code-flow traces: new subsec `sec:algo-traces` with three traces:
  (a) d=5 single WS `cws.x -w5 1 H -r`; (b) d=4 single WS (both forks:
  Make_IP_Weights vs Make_34_Weights); (c) d=4 all CWS `cws.x -c4`
  (Make_34_CWS hard-coded list). Ends with explicit d=4-vs-d=5 fork summary.

**2026-06-07 addition to ks_classification.tex (from arXiv:1808.02422,
Schoeller-Skarke):** new subsec `sec:algo-maxdeg` "Maximum degree for d=5 and
complete call graph", placed right after sec:algo-traces, before
\section{Key references}. Contents:
- Theorem `thm:maxdeg5` (eq `eq:maxdeg5`): d_max for d=5 single WS =
  3,263,442 = 2*3*7*43*1807 = 1806*1807 = product of first 5 Sylvester
  numbers. Extremal WS q^(6)_ct=(1/2,1/3,1/7,1/43,1/1807,1/3263442), integer
  weights (1631721,1087814,466206,75894,1806,1) (eqs eq:maxws5/eq:maxws5int).
  Reflexive; the "central upper tip" of (h11,h13) Hodge plot, Fig.1.
- Remark `rmk:maxdeg5`: why it's the true max (greedy Sylvester unit-fraction
  expansion maximizes denominator at each step; no other Rec_IpWeights branch
  can exceed it). So `-w5 1 3263442 -r` is exhaustive.
- verbatim full PALP call chain main->Init_IP_Weights->Make_IP_Weights->
  MakeIpWeights->Rec_IpWeights->IfIpWWrite->{Make_Poly_Points, IP_Check,
  reflexivity E.e[i].c!=1, Write_Weight}; prints #primepartitions/#refpolys.
- Remark `rmk:callgraph5` cross-refs each layer to the structural results.
- Paper arXiv:1808.02422 cited INLINE (no \cite/\bibitem; doc has no
  thebibliography, refs are an itemize list).

**2026-06-15 addition to ks_classification.tex:** new top-level
\section{The fibre of the map WS->NF...} (label `sec:fibre`), placed AFTER the
algorithm section (right after rmk:callgraph5) and BEFORE \section{Key
references}. Answers the user's four fibre questions. Subsections:
- sec:fibre-three: Def `def:threepoly` (the THREE polytopes per WS: minimal core
  nabla_q [d+1 verts, circuit relation], Newton polytope Delta_q [hull of all
  deg-d monomials, many verts, the one PALP NF-tests], NF). Factorization
  q --alpha--> Delta_q --beta--> NF (eq:phifactor); alpha=hull, beta=GL(d,Z)
  quotient.
- sec:fibre-finite (Q1): Thm `thm:fibrefinite` fibre finite via (a) global/metric
  [Hensley+Sylvester d_max=3263442] and (b) local/combinatorial [bound eq:fibrebound
  = #IP-simplex circuits in P]. Key: bijection eq:simplexws-bij {IP d-simplices}/GL
  <-> {len-(d+1) IP WS}/perm (Lemma lem:ipcrit) => WS is INVARIANT of simplex, not
  extra data; many-to-one originates in alpha/beta NOT the simplex. Rmk twofinite.
- sec:fibre-loss (Q2): Prop `prop:lossy` (alpha lossy=convex hull merges/discards;
  beta lossy=nonlocal GL quotient, NF is a certificate). Rmk manyseeds (deep reason:
  one maximal Delta contains several inequiv IP sub-simplices => idempotent NF_List).
  Rmk fibrequant: avg fibre ~2100 = 1.85e11 reflexive / 8.8e7 NF in d=5.
- sec:fibre-predict (Q3): four predictors: (1) necessary invariants from q (degree,
  multiset, Gorenstein w_i|d, Hodge, M:np nv N:np nv) = sieve, never sufficient;
  (2) reflexive-simplex sub-class FULLY predictable via Conrads (cheap circuit
  Hermite/Smith NF, ~3462 unit-fraction WS); (3) Z_k lattice-quotient coincidences
  (z/m/nz/index); (4) secondary affine/oriented-matroid symmetries (open in d=5).
  Rmk fibrenegative: general fibre NOT weight-local decidable.
- sec:fibre-naive (Q4): four naive checks (1 construct+NF compare=complete canonical;
  2 construct+brute GL search; 3 construct+invariant prefilter+NF; 4 oriented
  vertex-set equality=INCOMPLETE, misses GL-equiv). Rmk fibredesign.
- Heavily cross-refs existing labels (lem:ipcrit, prop:wsfinite, thm:maxdeg5,
  rmk:class-code, rmk:cwsstruct, rmk:nf-code, thm:cws5types, def:min). Also refs
  companion ws_vs_cws_pipelines.md inline.
- Also has sec:fibre-dichotomy (Thm thm:dichotomy simplex/non-simplex), sec:fibre-worked
  (3 worked d=5 examples ex:positive/ex:fp1/ex:fp2), sec:fibre-sieve (S0-S6 prioritized sieve).

**2026-06-15 SECOND addition to ks_classification.tex:** new subsec
`sec:fibre-gale` "Generalizing Conrads by Gale duality: the right objects, the
genuine obstruction, and the ceiling", inserted between sec:fibre-dichotomy and
sec:fibre-worked. Answers user's Q1 (generalize Conrads) and Q2 (best without
NF/hull) rigorously. Contents:
- Q1 via GALE DUALITY: Prop `prop:wsgale` (a (C)WS presents ker(hat A) = affine-
  relation space, dim g=n-d-1 = Gale dimension; single WS = the g=1 circuit, CWS
  = k independent circuits). Def `def:galedatum` (decorated Gale datum: chirotope
  chi_B + Smith/SNF arithmetic decoration + torsion H=N/<A>). Thm `thm:galerefine`
  + eq:refinechain: GL(d,Z)-equiv STRICTLY FINER than chirotope-equiv; gap =
  arithmetic decoration; g=1 chirotope trivial => only Smith form remains = exactly
  Conrads. Rmk `rmk:galeprogram` (two-step program: chirotope then decoration =
  complete GL invariant).
- Q2 obstruction: Thm `thm:obstruction` clean split (W) weight-local = everything
  DOWNSTREAM of the vertex set (Gale dual, chirotope, SNF, torsion = poly-time
  linear/integer algebra, no hull/NF) vs (H) provably needs hull = selecting
  WHICH monomials are VERTICES (per-point LP feasibility, not a function of weight
  multiset). Irreducible residue = lattice-polytope GL(d,Z)-iso problem. Rmk
  `rmk:obstruction`: hull unavoidable, but once done, replace beta(NF) by Gale datum.
- Q2 ceiling: Thm `thm:ceiling` Gale-dim hierarchy: g=0 simplices=Conrads done;
  g=1 (n=d+2) Grunbaum sign-on-a-line, generalized Conrads CLOSED FORM (the concrete
  novel target); g=2 (n=d+3) affine planar Gale diagram tractable; g>=3 explodes,
  sound-incomplete sieve only. Rmk `rmk:ceiling` (honest best = poly-time GL-invariant
  complete on g<=2, sound sieve on g>=3, provable residue). Rmk `rmk:surrounding`
  (GKZ secondary polytope/fan, A-discriminant, Gale diagrams Grunbaum/Sturmfels,
  arithmetic refinement of oriented matroids).
- Q2 EMPIRICAL CALIBRATION: Rmk `rmk:galecalib` (two tables: per-vertex nv=6..,
  cumulative g<=0,1,2,5,10) over FULL 2.377e9 NF / 1.853e11 WS. Rmk
  `rmk:galecalib-read` the punchline asymmetry: g<=2 = 0.096% of NFs BUT 8.68% of
  WS MASS (g<=5 = 37.5% WS); biggest fibre in whole classification (650,642,665 WS,
  the h11=28348 max-Hodge CY4, WS (62,81,491,1206,1647,1840)) is nv=7 = Gale dim 1.
  So program covers few NFs but front-loaded heaviest fibres => operationally worth it.
- 4 NEW REFERENCES added: GKZ 1994 (secondary polytope/A-discriminant), Grunbaum
  2003 (Gale diagrams/few-vertex polytopes), Ziegler 1995 (Gale transforms), BLSWZ
  1999 Oriented Matroids (chirotopes).
- Compiles clean (pdflatex x3, exit 0), now 35 pages, 0 undefined refs (only a
  harmless OMS/cmtt italic font-shape warning). New labels: sec:fibre-gale,
  prop:wsgale, def:galedatum, thm:galerefine, rmk:galeprogram, thm:obstruction,
  rmk:obstruction, thm:ceiling, rmk:ceiling, rmk:surrounding, rmk:galecalib,
  rmk:galecalib-read, eqs eq:Ahat/eq:galedim/eq:galedatum/eq:refinechain.

**Key CODE FACTS verified against PALP source (do not re-derive):**
- main() in cws.c dispatches on fn[1][1]: 'w'->Init_IP_Weights,
  'c'->Init_IP_CWS, 'd'->RgcWeights, 'm'->Init_moon_Weights, 'N'->Npoly2cws.
- Init_IP_Weights: with degree window L H -> Make_IP_Weights (partition
  recursion); WITHOUT -> Make_34_Weights (point-set constructor, assert d<=4).
- Init_IP_CWS: if -n flag OR d>4 -> Make_IP_CWS (generic, needs weight files
  + -t); else (d<=4) -> Make_34_CWS (hard-coded type list, assert d<=4).
- MakeIpWeights loop: `for(W.d=from_d;W.d<=to_d;W.d++) for(W.w[N-1]=W.d/2;
  W.d<=N*W.w[N-1];W.w[N-1]--) Rec_IpWeights(...,n=N-2,...)`. N=d+1.
- Make_34_CWS d=4 list (lines ~1801): 4uu4(u=2), 3u4(u=1), 3x3(u=0), 2x4(u=0),
  3u3x2, 3x2x2, 3u3u3, 2x2x2x2.
- PRINT_CWS (Only_IP_CWS): Make_CWS_Points->IP_Check->E.e[i].c==1->
  Make_Dual_Poly; prints M:np nv N:np ne (or F: if not reflexive).
- Signatures confirmed: IP_Check & Make_Dual_Poly in Vertex.c; Make_Poly_NF,
  GLZ_Make_Trian_NF, Make_VPM_NF in Polynf.c; Make_CWS_Points/Make_CWS_Basis/
  CWS_to_PermCWS in Coord.c.
- LaTeX gotcha: never put math underscores (w_0, v_i) inside \texttt{...};
  use $...$ or spell out (w0). Hit this once, fixed.

Section status:
- **Foundations of Toric Geometry** — PLACEHOLDER only (lattices/fans intro + a
  remark noting it is to be filled in). Cones, Cox ring, divisors, intersection
  theory still TODO.
- **Calabi--Yau Manifolds** — WRITTEN: Definition (4 equivalences), Yau's theorem,
  Hodge numbers/moduli.
- **Why Calabi--Yau Manifolds Matter** — WRITTEN: math significance, physics/string
  significance, remark tying to refpoly-5d / F-theory.
- **Reflexive Polyhedra** — WRITTEN: definition, properties (involution, single
  interior point, finiteness), Kreuzer--Skarke counts, P^2 simplex example.
- **Batyrev's Construction and Mirror Symmetry** — WRITTEN: Gorenstein-Fano
  equivalence, main hypersurface theorem w/ adjunction, quintic example, mirror
  symmetry via polar duality + Hodge-number formula.
- **Key Results from the Literature** — WRITTEN: Batyrev 1994, Yau 1978,
  CDGP 1991, Kreuzer--Skarke.

**How to apply:** Append to existing sections rather than duplicating. The Toric
Foundations section is the obvious next thing to flesh out. No \cite/bibliography
yet — references are inline text; consider adding a .bib if it grows.
Related: [[project-refpoly5d]], [[user-profile]].
