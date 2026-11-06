#!/usr/bin/env bash
# Design-system guardrails. Hard-fails on regressions we've fully cleaned up;
# budget-checks the two large in-flight migrations so their counts can only
# shrink. Run from the repo root.
set -uo pipefail

SRC="ConnectSphere"
fail=0

# grep exits 1 on no matches; that's fine here, so swallow it.
count() { grep -rn "$1" "$SRC" --include='*.swift' 2>/dev/null | grep -v '//' | grep -c '' || true; }

# ── Hard fails ──────────────────────────────────────────────────────────────
purple_orange=$(count 'Color\.\(purple\|orange\)')
if [ "$purple_orange" -ne 0 ]; then
  echo "FAIL: $purple_orange raw Color.purple/.orange literal(s). Use theme.primary or AppColors.warning"
  grep -rn 'Color\.\(purple\|orange\)' "$SRC" --include='*.swift' | grep -v '//'
  fail=1
fi

apptheme=$(grep -rn 'AppTheme\.\|AppGradient' "$SRC" --include='*.swift' 2>/dev/null | grep -v '// \|Replaces AppTheme' | wc -l | tr -d ' ')
if [ "$apptheme" -ne 0 ]; then
  echo "FAIL: AppTheme / AppGradient reference(s) reintroduced. Both were deleted"
  fail=1
fi

# ── Budget checks (counts must not increase) ────────────────────────────────
FONT_BUDGET=638
fonts=$(count '\.font(\.system(size:')
if [ "$fonts" -gt "$FONT_BUDGET" ]; then
  echo "FAIL: inline .font(.system(size:)) went up ($fonts > $FONT_BUDGET). Use .appFont(_:). Lower the budget when you migrate some."
  fail=1
else
  echo "ok: inline font sites $fonts / $FONT_BUDGET"
fi

HEX_BUDGET=52
hex=$(grep -rn 'Color(hex:' "$SRC" --include='*.swift' 2>/dev/null \
  | grep -vE 'AppColors\.swift|ThemeManager\.swift|AuthComponents\.swift|MockData\.swift' \
  | grep -v "//" | grep -c "" || true)
if [ "$hex" -gt "$HEX_BUDGET" ]; then
  echo "FAIL: Color(hex:) outside the theme layer went up ($hex > $HEX_BUDGET). Prefer AppColors / palette tokens."
  fail=1
else
  echo "ok: Color(hex:) outside theme $hex / $HEX_BUDGET"
fi

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "design lint passed"
