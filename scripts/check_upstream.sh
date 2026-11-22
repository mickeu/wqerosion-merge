#!/bin/sh
# Report whether the two upstreams moved past our baseline (see docs/UPSTREAM.md).
WQ_BASE=a8a4d06cbf2651de1cd7bd9f5f8e38f67b025890
ER_BASE=8ef12aa53bd82869bebc6cf4d22eef7bb15ac65f
WQ=$(git ls-remote https://github.com/kolbicz/WQFiles HEAD 2>/dev/null | cut -f1)
ER=$(git ls-remote https://github.com/Kianuni/Erosion-CN HEAD 2>/dev/null | cut -f1)
echo "WQFiles  base=$WQ_BASE"
echo "         remote=$WQ"
[ "$WQ" = "$WQ_BASE" ] && echo "  -> up to date" || echo "  -> NEW upstream commits; follow the sync flow in docs/UPSTREAM.md"
echo "Erosion  base=$ER_BASE"
echo "         remote=$ER"
[ "$ER" = "$ER_BASE" ] && echo "  -> up to date" || echo "  -> NEW upstream commits; follow the sync flow in docs/UPSTREAM.md"
