#!/bin/bash

#======================#
#  Comprehensive Reconnaissance Script
#======================#
# Usage:
#   ./script.sh enum <domain> <output_folder>
#   ./script.sh httpx <output_folder> <subdomains_file>
#======================#

set -e
YOUR_CHAOS_API_KEY='chaos_api_key'
YOUR_GITHUB_TOKEN='github_api_key'

# Subdomain Enumeration Function
enumeration_subdomains_process() {
    local domain=$1
    local output_folder="$2/subdomain_enumeration"

    mkdir -p "$output_folder"

    echo "[*] Running subfinder..."
    subfinder -d "$domain" -recursive -all -silent -o "$output_folder/subfinder_output.txt"

    echo "[*] Running assetfinder..."
    assetfinder -subs-only "$domain" > "$output_folder/assetfinder_output.txt"

    echo "[*] Running crtsh.py..."
    python3 ~/Tools/crtsh.py/crtsh.py -d "$domain" -r > "$output_folder/crtsh_output.txt"

    echo "[*] Running findomain..."
    findomain --target "$domain" -u "$output_folder/findomain_output.txt"

    echo "[*] Running subscraper..."
    python3 ~/Tools/subscraper/subscraper.py -d "$domain" \
        -o "$output_folder/subscraper_output.txt" \
        -w /usr/share/seclists/Discovery/DNS/subdomains-top1million-110000.txt

    echo "[*] Running github-subdomains.py..."
    
    python3 ~/Tools/github-search/github-subdomains.py \
        -t $YOUR_GITHUB_TOKEN -d "$domain" > "$output_folder/github_output.txt"

    echo "[*] Running chaos..."
    
    export PDCP_API_KEY=$YOUR_CHAOS_API_KEY
    chaos -d "$domain" > "$output_folder/chaos_output.txt"

    echo "[*] Running dnsx..."
    dnsx -d "$domain" \
        -w /usr/share/seclists/Discovery/DNS/subdomains-top1million-110000.txt \
        -o "$output_folder/dnsx_output.txt"

    echo "[*] Running hackertarget..."
    curl -s "https://api.hackertarget.com/hostsearch/?q=$domain" | cut -d',' -f1 > "$output_folder/hackertarget_output.txt"

    echo "[*] Running waybackurls..."
    echo "$domain" | waybackurls | grep -oP 'https?://\K[^/]+' | \
        sed 's/:[0-9]\{1,5\}//g' | sort -u > "$output_folder/waybackurls_output.txt"

    echo "[*] Running gau..."
    echo "$domain" | gau | grep -oP 'https?://\K[^/]+' | \
        sed 's/:[0-9]\{1,5\}//g' | sort -u > "$output_folder/gau_output.txt"

    echo "[*] Running amass..."
    amass enum -d "$domain" -o "$output_folder/amass_output.txt"
    grep '(FQDN)' "$output_folder/amass_output.txt" | cut -d' ' -f1 | sort -u > "$output_folder/amass_fqdn_output.txt"

    echo "[*] Running Sudomy..."
    sudomy -d "$domain" -o "$output_folder/sudomy_output"

    echo "[*] Combining outputs..."
    cat "$output_folder"/*_output.txt "$output_folder/sudomy_output/*.txt" | sort -u > "$output_folder/combined_subdomains.txt"
    echo "[+] All subdomain outputs saved to $output_folder/combined_subdomains.txt"
}

# HTTP Validation and Post-Enumeration Function
httpx() {
    local output_folder="$1"
    local input_file="$2"
    local wordlist="/usr/share/seclists/Discovery/Web-Content/common.txt"

    mkdir -p "$output_folder"

    echo "[*] Running httpx for live subdomains..."
    httpx -l "$input_file" -silent -o "$output_folder/httpx_output.txt"

    echo "[*] Running httpx with status, tech, and title..."
    httpx -l "$input_file" -status-code -tech-detect -title -o "$output_folder/httpx_full_output.txt"

    echo "[*] Taking screenshots..."
    httpx -l "$input_file" -screenshot -o "$output_folder/httpx_screenshots.txt"

    echo "[*] Running waybackurls..."
    cat "$output_folder/httpx_output.txt" | waybackurls | sort -u > "$output_folder/waybackurls_output.txt"

    echo "[*] Running gau..."
    cat "$output_folder/httpx_output.txt" | gau | sort -u > "$output_folder/gau_output.txt"

    echo "[*] Running nuclei scan..."
    nuclei -l "$output_folder/httpx_output.txt" -o "$output_folder/nuclei_output.txt"

    echo "[*] Running gobuster..."
    while read -r domain; do
        gobuster dir -u "http://$domain" -w "$wordlist" -q \
            -o "$output_folder/gobuster_${domain//[^a-zA-Z0-9]/_}.txt"
    done < "$output_folder/httpx_output.txt"

    echo "[*] Running ffuf..."
    while read -r domain; do
        ffuf -w "$wordlist":FUZZ -u "http://$domain/FUZZ" \
            -o "$output_folder/ffuf_${domain//[^a-zA-Z0-9]/_}.json" -of json
    done < "$output_folder/httpx_output.txt"

    echo "[*] Running hakrawler..."
    mkdir -p "$output_folder/hakrawler_output"
    while read -r domain; do
        hakrawler -url "http://$domain" -depth 2 -plain > "$output_folder/hakrawler_output/${domain//[^a-zA-Z0-9]/_}_urls.txt"
    done < "$output_folder/httpx_output.txt"

    echo "[*] Fetching JavaScript files using subjs..."
    mkdir -p "$output_folder/js_files"
    cat "$output_folder/httpx_output.txt" | subjs -c 40 > "$output_folder/js_files/js_urls.txt"

    echo "[*] Extracting endpoints from JavaScript files using xnLinkFinder..."
    mkdir -p "$output_folder/js_links"
    while read -r js_url; do
        echo "[+] Analyzing $js_url..."
        python3 xnLinkFinder.py -i "$js_url" -o cli >> "$output_folder/js_links/xnlinkfinder_output.txt"
    done < "$output_folder/js_files/js_urls.txt"

    echo "[*] Running Arjun for parameter discovery..."
    mkdir -p "$output_folder/arjun_output"
    while read -r url; do
        arjun -u "$url" --get -oT "$output_folder/arjun_output/$(echo $url | sed 's/[^a-zA-Z0-9]/_/g').txt"
    done < "$output_folder/httpx_output.txt"

    echo "[+] HTTP validation and post-enumeration complete. Results saved in $output_folder"
}

# Dispatcher
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "$1" == "enum" && $# -eq 3 ]]; then
        enumeration_subdomains_process "$2" "$3"
    elif [[ "$1" == "httpx" && $# -eq 3 ]]; then
        httpx "$2" "$3"
    else
        echo "Usage:"
        echo "  $0 enum <domain> <output_folder>       # Run subdomain enumeration"
        echo "  $0 httpx <output_folder> <input_file>  # Validate subdomains & scan"
        exit 1
    fi
fi
