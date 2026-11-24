#!/bin/bash
cd "/d/小肥鱼工作区/07-影音App/qingshu-merge" || exit 1
TK=$(git remote get-url origin | sed -E "s#.*x-access-token:([^@]*)@.*#\1#")
for i in $(seq 1 60); do
  TS=$(date +%s)
  curl -sL --max-time 20 -H "Authorization: Bearer ${TK}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/lzjloveyjx/qingshu-base/actions/runs/45335601999?_t=${TS}" -o m6.json
  RES=$(node -e "const d=require('./m6.json'); process.stdout.write((d.status||'')+'|'+(d.conclusion||''))")
  echo "check $i: $RES"
  case "$RES" in completed*) echo "$RES" > m6_result.txt; exit 0;; esac
  sleep 25
done
echo TIMEOUT > m6_result.txt
