/**
 * maxcheck_cli.cpp — stdin driver for palp_max_check, for validation.
 *
 * Input: one polytope per line as
 *        `dim nv  m[0][0] m[0][1] ... m[dim-1][nv-1]`
 *   i.e. the row-major [dim x nv] NF vertex matrix (same layout as the
 *   `nf` column of unique_polytopes_clean.parquet).
 * Output per line: `<code> nv=<hull_nv> ne=<facets>`
 *   code: MAX (r-maximal), NONMAX (reflexive, not maximal),
 *         NONREF, NOTIP, ERR.
 */
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <chrono>

#include "palp_maxcheck.h"

static const char *code_name(int c) {
    switch (c) {
        case MAXCHK_REF_MAX:    return "MAX";
        case MAXCHK_REF_NONMAX: return "NONMAX";
        case MAXCHK_NONREF:     return "NONREF";
        case MAXCHK_NOT_IP:     return "NOTIP";
        case MAXCHK_OVERFLOW:   return "OVERFLOW";
        default:                return "ERR";
    }
}

int main() {
    maxchk_init_io();
    MaxWorkspace *w = maxws_alloc();
    if (!w) { std::cerr << "alloc failed\n"; return 2; }

    std::string line;
    while (std::getline(std::cin, line)) {
        std::istringstream iss(line);
        std::vector<int> t;
        for (int x; iss >> x;) t.push_back(x);
        if (t.size() < 2) continue;
        int dim = t[0], nv = t[1];
        if ((int)t.size() != 2 + dim * nv) {
            std::cout << "ERR (bad token count)\n";
            continue;
        }
        auto t0 = std::chrono::steady_clock::now();
        int code = palp_max_check(w, t.data() + 2, dim, nv);
        auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                      std::chrono::steady_clock::now() - t0).count();
        std::cout << code_name(code)
                  << " nv=" << w->last_nv
                  << " ne=" << w->last_ne
                  << " us=" << us << '\n';
        std::cout.flush();
    }
    maxws_free(w);
    return 0;
}
