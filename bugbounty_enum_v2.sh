#!/bin/bash

# --------------- CONFIGURATION ------------------
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --------------- ARGUMENT PARSING ---------------
usage() {
  echo -e "\nUsage: $0 -l <domains.txt> -o <output_dir> --chaos-key <key> --github-token <token> -m <module>"
  echo -e "\nModules: all, subdomain, httpx, nuclei, js"
  exit 1
}

DOMAINS=""
OUTPUT=""
CHAOS_KEY=""
GITHUB_TOKEN=""
MODULE=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -l) DOMAINS="$2"; shift 2 ;;
    -o) OUTPUT="$2"; shift 2 ;;
    --chaos-key) CHAOS_KEY="$2"; shift 2 ;;
    --github-token) GITHUB_TOKEN="$2"; shift 2 ;;
    -m) MODULE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$DOMAINS" || -z "$OUTPUT" || -z "$CHAOS_KEY" || -z "$GITHUB_TOKEN" ]] && usage
: "${MODULE:=all}"

# --------------- HELPER FUNCTIONS ----------------
run_tool() {
  TOOL_NAME="$1"
  CMD="$2"
  echo -e "${YELLOW}[+] Running $TOOL_NAME...${NC}"
  eval "$CMD" || echo -e "${RED}[-] $TOOL_NAME failed for $DOMAIN${NC}"
}

run_knockpy_scripted() {
  local DOMAIN="$1"
  local OUTDIR="$2"
  echo -e "${YELLOW}[+] Running knockpy on $DOMAIN...${NC}"
  START=$(date +%s)
  script -q -c "knockpy -o \"$OUTDIR/knockpy\" \"$DOMAIN\" > /dev/null 2> \"$OUTDIR/knockpy_error.log\"" /dev/null
  local KNOCKPY_JSON=$(find "$OUTDIR/knockpy" -type f -name "*.json" | head -n1)
  if [ -n "$KNOCKPY_JSON" ]; then
    jq -r 'keys[] | select(. != "_meta")' "$KNOCKPY_JSON" | sort -u > "$OUTDIR/knockpy.txt"
  else
    touch "$OUTDIR/knockpy.txt"
  fi
  END=$(date +%s)
  echo -e "${GREEN}[✔] knockpy took $((END - START)) seconds for $DOMAIN${NC}"
}

run_subscraper_scripted() {
  local DOMAIN="$1"
  local OUTDIR="$2"
  echo -e "${YELLOW}[+] Running subscraper on $DOMAIN...${NC}"
  START=$(date +%s)
  script -q -c "python3 /opt/subscraper/subscraper.py -d \"$DOMAIN\" -o \"$OUTDIR/subscraper.txt\" -w /usr/share/seclists/Discovery/DNS/subdomains-top1million-110000.txt > /dev/null 2> \"$OUTDIR/subscraper_error.log\"" /dev/null
  END=$(date +%s)
  echo -e "${GREEN}[✔] subscraper took $((END - START)) seconds for $DOMAIN${NC}"
}

# --------------- MODULES -------------------------
run_subdomain_enum() {
  DOMAIN="$1"
  OUTDIR="$2/$DOMAIN/subdomain"
  mkdir -p "$OUTDIR"

  echo "[i] Running subdomain enumeration for $DOMAIN..."
  run_tool "subfinder" "subfinder -d $DOMAIN -silent > $OUTDIR/subfinder.txt"
  run_tool "assetfinder" "assetfinder --subs-only $DOMAIN > $OUTDIR/assetfinder.txt"
  run_tool "findomain" "findomain -t $DOMAIN -q > $OUTDIR/findomain.txt"
  run_tool "crt.sh" "curl -s 'https://crt.sh/?q=%25.$DOMAIN&output=json' | jq -r '.[].name_value' | sed 's/\\*\\.//g' | sort -u > $OUTDIR/crtsh.txt"
  run_tool "chaos" "chaos -key $CHAOS_KEY -d $DOMAIN -silent > $OUTDIR/chaos.txt"
  run_tool "github-subdomains" "python3 /opt/github-search/github-subdomains.py -d $DOMAIN -t $GITHUB_TOKEN > $OUTDIR/github.txt"
  run_knockpy_scripted "$DOMAIN" "$OUTDIR"
  run_subscraper_scripted "$DOMAIN" "$OUTDIR"

  # Merge all results into unique list
  cat "$OUTDIR"/*.txt 2>/dev/null | grep -iEo "([a-zA-Z0-9_-]+\.)+$DOMAIN" | sort -u > "$2/$DOMAIN/all_subdomains.txt"
}

run_httpx_enum() {
  DOMAIN="$1"
  OUTDIR="$2/$DOMAIN/httpx"
  mkdir -p "$OUTDIR"
  echo "[i] Running httpx on subdomains of $DOMAIN..."
  ~/go/bin/httpx -l "$2/$DOMAIN/all_subdomains.txt" -silent -status-code -title -tech-detect -json -o "$OUTDIR/httpx.json"
  jq -r '.url' < "$OUTDIR/httpx.json" > "$OUTDIR/alive.txt"
  echo "[i] Taking screenshots with gowitness..."
 
}

run_nuclei_enum() {
  DOMAIN="$1"
  OUTDIR="$2/$DOMAIN/nuclei"
  mkdir -p "$OUTDIR"
  echo "[i] Running nuclei on $DOMAIN..."
  nuclei -l "$2/$DOMAIN/httpx/alive.txt" -o "$OUTDIR/nuclei.txt" -silent

}

run_js_enum() {
  DOMAIN="$1"
  OUTDIR="$2/$DOMAIN/js"
  mkdir -p "$OUTDIR"
  echo "[i] Running JS/link enumeration on $DOMAIN..."
  run_tool "hakrawler" "cat $2/$DOMAIN/httpx/alive.txt | hakrawler -subs -depth 3 > $OUTDIR/hakrawler.txt"
  run_tool "subjs" "subjs -i $2/$DOMAIN/httpx/alive.txt > $OUTDIR/subjs.txt"
  run_tool "gospider" "gospider -S $2/$DOMAIN/httpx/alive.txt -d 2 --no-redirect -t 5 -o $OUTDIR/gospider"
  run_tool "waybackurls" "cat $2/$DOMAIN/all_subdomains.txt | waybackurls > $OUTDIR/wayback.txt"
  run_tool "gau" "cat $2/$DOMAIN/all_subdomains.txt | gau > $OUTDIR/gau.txt"
  run_tool "paramspider" "paramspider -l $2/$DOMAIN/httpx/alive.txt > $OUTDIR/paramspider.txt 2> $OUTDIR/paramspider_error.log"
  run_tool "arjun" "arjun -i $2/$DOMAIN/httpx/alive.txt -oT $OUTDIR/arjun.txt"
}

# --------------- MAIN EXECUTION ------------------
mapfile -t DOMAIN_LIST < "$DOMAINS"

for domain in "${DOMAIN_LIST[@]}"; do
  {
    [[ -z "$domain" ]] && continue
    echo -e "\n${GREEN}[*] Processing $domain...${NC}"

    case "$MODULE" in
      all)
        run_subdomain_enum "$domain" "$OUTPUT" || echo "[-] Failed: subdomain"
        run_httpx_enum "$domain" "$OUTPUT" || echo "[-] Failed: httpx"
        run_js_enum "$domain" "$OUTPUT" || echo "[-] Failed: js"
        run_nuclei_enum "$domain" "$OUTPUT" || echo "[-] Failed: nuclei"
        ;;
      subdomain) run_subdomain_enum "$domain" "$OUTPUT" ;;
      httpx) run_httpx_enum "$domain" "$OUTPUT" ;;
      nuclei) run_nuclei_enum "$domain" "$OUTPUT" ;;
      js) run_js_enum "$domain" "$OUTPUT" ;;
      *) echo -e "${RED}[-] Unknown module: $MODULE${NC}"; usage ;;
    esac
  } || echo -e "${RED}[-] Error while processing $domain, continuing...${NC}"
done

echo -e "\n${GREEN}[✔] Enumeration complete. Results stored in $OUTPUT${NC}"
