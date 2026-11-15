#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Check that robot-gate.py hands itself to the pinned $CSIT_PYTHON.
#
# run-test.sh starts the gate with the caller's python3; the action passes its
# pinned interpreter as CSIT_PYTHON, and the gate re-runs itself under it once,
# with its arguments intact. The report step already starts --summary under
# the pinned interpreter, so --summary must ignore an inherited CSIT_PYTHON.
#
# The pinned interpreter is a wrapper created here that logs each call and
# then runs the real python3, so the handoff is observable.
#
# Usage: bash tests/test-pinned-python.sh
##############################################################################

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="${here}/../scripts/robot-gate.py"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

export GITHUB_STEP_SUMMARY="${tmp}/step-summary.md"
unset CSIT_PYTHON

fail=0
pass() { echo "ok: $1"; }
flunk() {
    echo "FAIL: $1"
    fail=1
}

real_python="$(command -v python3)"
log="${tmp}/wrapper.log"
wrapper="${tmp}/pinned-python"
# One line per call: whether CSIT_PYTHON reached it, then each argument.
cat >"${wrapper}" <<EOF
#!/usr/bin/env bash
{
    printf 'CSIT_PYTHON=%s' "\${CSIT_PYTHON-<unset>}"
    printf ' [%s]' "\$@"
    printf '\n'
} >>"${log}"
exec "${real_python}" "\$@"
EOF
chmod +x "${wrapper}"

# $1 output.xml path, $2 pass count, $3 fail count
results() {
    cat >"$1" <<EOF
<robot><statistics><total>
<stat pass="$2" fail="$3">All Tests</stat>
</total></statistics></robot>
EOF
}

results "${tmp}/green.xml" 9 0
results "${tmp}/red.xml" 8 1

# --- gate mode hands off --------------------------------------------------
: >"${log}"
set +e
CSIT_PYTHON="${wrapper}" python3 "${gate}" "${tmp}/green.xml" 100.0 0.0 \
    >/dev/null 2>&1
rc=$?
set -e
want="CSIT_PYTHON=<unset> [${gate}] [${tmp}/green.xml] [100.0] [0.0]"
if [ "${rc}" -eq 0 ]; then
    pass "gate under the pinned interpreter passes a green run"
else
    flunk "gate under the pinned interpreter exited ${rc} on a green run"
fi
if [ "$(wc -l <"${log}")" -eq 1 ]; then
    pass "gate re-runs itself exactly once"
else
    flunk "expected one call to the pinned interpreter, log:"
    cat "${log}"
fi
if [ "$(head -n 1 "${log}")" = "${want}" ]; then
    pass "handoff keeps the arguments and drops CSIT_PYTHON"
else
    flunk "handoff call differs"
    echo "      want: ${want}"
    echo "      got:  $(head -n 1 "${log}")"
fi

# The verdict of the re-run process is the gate's exit code.
: >"${log}"
set +e
CSIT_PYTHON="${wrapper}" python3 "${gate}" "${tmp}/red.xml" 100.0 0.0 \
    >/dev/null 2>&1
rc=$?
set -e
if [ "${rc}" -eq 1 ] && [ -s "${log}" ]; then
    pass "a failing run still fails under the pinned interpreter"
else
    flunk "failing run under the pinned interpreter exited ${rc}"
fi

# A pinned path that does not run must fail the gate, never fall back.
if CSIT_PYTHON="${tmp}/absent-python" python3 "${gate}" "${tmp}/green.xml" \
    100.0 0.0 >/dev/null 2>&1; then
    flunk "gate ignored a CSIT_PYTHON it could not run"
else
    pass "gate honours CSIT_PYTHON rather than its own interpreter"
fi

# --- summary mode ignores it ----------------------------------------------
mkdir -p "${tmp}/results/job-green"
cp "${tmp}/green.xml" "${tmp}/results/job-green/output.xml"

: >"${log}"
: >"${GITHUB_STEP_SUMMARY}"
if (cd "${tmp}" && CSIT_PYTHON="${tmp}/absent-python" \
    python3 "${gate}" --summary results "" >/dev/null 2>&1) &&
    grep -qF "1/1 jobs green" "${GITHUB_STEP_SUMMARY}"; then
    pass "summary ignores an inherited CSIT_PYTHON"
else
    flunk "summary followed an inherited CSIT_PYTHON"
fi

if (cd "${tmp}" && CSIT_PYTHON="${wrapper}" \
    python3 "${gate}" --summary results "" >/dev/null 2>&1) &&
    [ ! -s "${log}" ]; then
    pass "summary does not re-run itself"
else
    flunk "summary re-ran under CSIT_PYTHON"
fi

exit "${fail}"
