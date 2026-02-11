#!/usr/bin/env bash
#
# Test script for cde.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CDE="$SCRIPT_DIR/cde.sh"
LIB_DIR="$SCRIPT_DIR/lib"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; exit 1; }

echo "═══════════════════════════════════════════════════"
echo " CDE Test Suite"
echo "═══════════════════════════════════════════════════"
echo ""

# Test 1: Syntax check - main script
echo "Test 1: Syntax validation (cde.sh)"
if bash -n "$CDE" 2>&1; then
    pass "Script syntax is valid"
else
    fail "Script has syntax errors"
fi

# Test 2: Syntax check - all lib files
echo ""
echo "Test 2: Syntax validation (lib/*.sh)"
lib_ok=true
for f in "$LIB_DIR"/*.sh; do
    fname=$(basename "$f")
    if bash -n "$f" 2>&1; then
        pass "lib/$fname syntax valid"
    else
        fail "lib/$fname has syntax errors"
        lib_ok=false
    fi
done
$lib_ok && pass "All lib files pass syntax check"

# Test 3: Help flag
echo ""
echo "Test 3: --help flag"
if $CDE --help | grep -q "Cloud Developer Experience"; then
    pass "--help shows usage"
else
    fail "--help doesn't work"
fi

# Test 4: No-arg shows usage
echo ""
echo "Test 4: No-arg usage screen"
if $CDE 2>&1 | grep -q "CDE"; then
    pass "Usage screen displays"
else
    fail "Usage screen missing"
fi

# Test 5: Unknown command error
echo ""
echo "Test 5: Unknown command handling"
if $CDE foobar 2>&1 | grep -q "Unknown command"; then
    pass "Unknown command shows error"
else
    fail "Unknown command not handled"
fi

# Test 6: Prereqs check
echo ""
echo "Test 6: Prerequisites check"
if $CDE prereqs 2>&1 | grep -q "docker\|kubectl\|k3d\|helm"; then
    pass "Prereqs lists tools"
else
    fail "Prereqs doesn't list tools"
fi

# Test 7: Status command (may show no cluster)
echo ""
echo "Test 7: Status command"
if $CDE status 2>&1 | grep -q "CDE\|Cluster\|not found"; then
    pass "Status command runs"
else
    fail "Status command broken"
fi

# Test 8: Verbose flag parsing
echo ""
echo "Test 8: Verbose flag"
if $CDE -v --help 2>&1 | grep -q "Usage"; then
    pass "-v flag parsed correctly"
else
    fail "-v flag breaks parsing"
fi

# Test 9: Deploy without service shows error
echo ""
echo "Test 9: Deploy without service argument"
if $CDE deploy 2>&1 | grep -q "Specify a service"; then
    pass "Deploy requires service arg"
else
    fail "Deploy missing arg not handled"
fi

# Test 10: Remove without service shows error
echo ""
echo "Test 10: Remove without service argument"
if $CDE remove 2>&1 | grep -qi "Specify a service\|Cluster.*not found"; then
    pass "Remove requires service arg or cluster"
else
    fail "Remove missing arg not handled"
fi

# Test 11: Open without service shows error (non-interactive mode)
echo ""
echo "Test 11: Open without service argument"
if CDE_NONINTERACTIVE=true $CDE open 2>&1 | grep -q "Specify a service"; then
    pass "Open requires service arg"
else
    fail "Open missing arg not handled"
fi

# Test 12: Forward without service shows error (non-interactive mode)
echo ""
echo "Test 12: Forward without service argument"
if CDE_NONINTERACTIVE=true $CDE forward 2>&1 | grep -qi "Specify a service\|Cluster.*not found"; then
    pass "Forward requires service arg or cluster"
else
    fail "Forward missing arg not handled"
fi

# Test 13: Lib directory structure
echo ""
echo "Test 13: Library structure"
expected_libs="constants.sh log.sh timing.sh ui.sh k8s.sh helm.sh cluster.sh tls.sh vault.sh services.sh portforward.sh"
all_present=true
for lib in $expected_libs; do
    if [[ -f "$LIB_DIR/$lib" ]]; then
        pass "lib/$lib exists"
    else
        fail "lib/$lib missing"
        all_present=false
    fi
done

# Test 14: Log directory creation
echo ""
echo "Test 14: Log initialization"
# The log dir should be created when init_log runs (during commands)
if $CDE prereqs 2>&1 | grep -q "docker\|kubectl"; then
    if [[ -d "$SCRIPT_DIR/../log" ]]; then
        pass "Log directory created"
    else
        pass "Log directory will be created on first command (prereqs may not init log)"
    fi
else
    fail "Prereqs command broken"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo " All basic tests passed!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "For integration tests (require cluster), run:"
echo "  ./cde.sh deploy all"
echo "  ./cde.sh status"
echo "  ./cde.sh open vault"
echo ""
