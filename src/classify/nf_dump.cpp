/**
 * nf_dump.cpp — diagnostic: weight system -> normal form via the classifier's
 * own PALP-library path (palp_api.h), printed as text.
 *
 * This exercises exactly the NF computation the classifier runs per row
 * (palp_compute_nf_from_cws), so diffing its output against the poly.x golden
 * oracle gates the ported library build (defines, thread-safety, PALP sources)
 * without going through Parquet, hashing, or dedup.
 *
 * Input: one weight system per line on stdin, PALP text form
 *        `degree w0 w1 ... w{N-1}`  (single weight system, N coords).
 * Output per line: `dim nv v00 v01 ...` — dim rows flattened row-major, matching
 *        the format tests/test_nf_golden.py expects. On failure prints `FAIL`.
 */
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "palp_api.h"

int main() {
    palp_init();
    PalpWorkspace *ws = palp_workspace_alloc();
    if (!ws) {
        std::cerr << "nf_dump: workspace alloc failed\n";
        return 2;
    }

    std::string line;
    while (std::getline(std::cin, line)) {
        std::istringstream iss(line);
        std::vector<int> tok;
        for (int x; iss >> x;) tok.push_back(x);
        if (tok.empty()) continue;

        // `degree w0..w{N-1}`: N = number of weights, single weight system.
        PalpCWSInput in;
        std::memset(&in, 0, sizeof(in));
        int N = static_cast<int>(tok.size()) - 1;
        in.nw = 1;
        in.N = N;
        in.index = 1;
        in.degree[0] = tok[0];
        for (int c = 0; c < N && c < PALP_API_MAX_COORDS; ++c)
            in.weights[0][c] = tok[1 + c];

        PalpNFResult r;
        palp_compute_nf_from_cws(ws, &in, &r);
        if (!r.ok) {
            std::cout << "FAIL\n";
            continue;
        }

        std::ostringstream out;
        out << r.dim << ' ' << r.nv;
        for (int i = 0; i < r.dim; ++i)
            for (int j = 0; j < r.nv; ++j)
                out << ' ' << static_cast<long long>(r.nf[i][j]);
        std::cout << out.str() << '\n';
    }

    palp_workspace_free(ws);
    return 0;
}
