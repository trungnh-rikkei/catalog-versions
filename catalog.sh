#!/usr/bin/env bash
# catalog.sh
# Usage:
#   ./catalog.sh          # Sync with default catalog
#   ./catalog.sh compose  # Sync with Compose catalog
#
# Requires: bash 3+, curl

set -euo pipefail

URL_DEFAULT="https://raw.githubusercontent.com/trungnh-rikkei/catalog-versions/main/gradle/libs.versions.toml"
URL_COMPOSE="https://raw.githubusercontent.com/trungnh-rikkei/catalog-versions/main/gradle/libs-compose.versions.toml"

CONNECT_TIMEOUT=10
READ_TIMEOUT=30
LOCAL_PATH="gradle/libs.versions.toml"

ARG="${1:-}"
if [[ "$ARG" == "compose" ]]; then
    URL="$URL_COMPOSE"
elif [[ -z "$ARG" ]]; then
    URL="$URL_DEFAULT"
else
    echo "Usage: $0 [compose]" >&2
    exit 1
fi

# ── Temp file (cleaned up on exit) ────────────────────────────────────────────
TMP_FILE=$(mktemp)
MERGE_TMP=$(mktemp)
trap 'rm -f "$TMP_FILE" "$MERGE_TMP"' EXIT

# ──────────────────────────────────────────────────────────────────────────────
# fetch_to_file <url> <dest>
# Downloads URL to dest file.
# Returns curl exit code (0 = success, non-zero = failure).
# ──────────────────────────────────────────────────────────────────────────────
fetch_to_file() {
    local url="$1" dest="$2"
    local curl_args=(
        -s --fail
        --connect-timeout "$CONNECT_TIMEOUT"
        --max-time        "$READ_TIMEOUT"
        -H "Accept: text/plain, */*"
        -H "Cache-Control: no-cache"
        -H "Pragma: no-cache"
        -o "$dest"
    )
    curl "${curl_args[@]}" "$url"
}

# ──────────────────────────────────────────────────────────────────────────────
# parse_toml_entries <toml-file>
# Outputs "SECTION<TAB>KEY<TAB>VALUE_LINE" for every key-value in every section.
# ──────────────────────────────────────────────────────────────────────────────
parse_toml_entries() {
    awk '
    BEGIN { sec = "" }
    {
        line = $0
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line == "") next
        if (substr(line, 1, 1) == "[") {
            tmp = line
            sub(/^\[/, "", tmp)
            sub(/\].*$/, "", tmp)
            gsub(/^[ \t]+|[ \t]+$/, "", tmp)
            sec = tmp; next
        }
        if (sec != "" && substr(line, 1, 1) != "#" && index(line, "=") > 0) {
            eq = index(line, "=")
            key = substr(line, 1, eq - 1)
            gsub(/^[ \t]+|[ \t]+$/, "", key)
            if (key != "") print sec "\t" key "\t" $0
        }
    }' "$1"
}

# ──────────────────────────────────────────────────────────────────────────────
# show_diff <local-file> <remote-file>
# Prints [ADDED] / [CHANGED] for remote entries vs local.
# Local-only entries are NOT shown (they are expected and OK).
# Returns 0 if there are changes, 1 if all remote entries match.
# ──────────────────────────────────────────────────────────────────────────────
show_diff() {
    local local_file="$1" remote_file="$2"
    local local_entries remote_entries
    local_entries=$(parse_toml_entries "$local_file")
    remote_entries=$(parse_toml_entries "$remote_file")

    local has_change=false
    while IFS=$'\t' read -r sec key raw_line; do
        [[ -z "$key" ]] && continue
        local rval
        rval=$(echo "$raw_line" | sed 's/^[^=]*=[ ]*//')
        local lline
        lline=$(printf '%s\n' "$local_entries" | awk -F'\t' -v s="$sec" -v k="$key" '$1==s && $2==k {print $3}')
        if [[ -z "$lline" ]]; then
            echo "  [ADDED]   [$sec] $key: $rval"; has_change=true
        else
            local lval
            lval=$(echo "$lline" | sed 's/^[^=]*=[ ]*//')
            if [[ "$lval" != "$rval" ]]; then
                echo "  [CHANGED] [$sec] $key: $lval -> $rval"; has_change=true
            fi
        fi
    done <<< "$remote_entries"

    $has_change
}

# ──────────────────────────────────────────────────────────────────────────────
# test_catalog_in_sync <local-file> <remote-file>
# Returns 0 if all remote entries exist in local with same trimmed value.
# Returns 1 otherwise.
# ──────────────────────────────────────────────────────────────────────────────
test_catalog_in_sync() {
    local local_file="$1" remote_file="$2"
    local local_entries remote_entries
    local_entries=$(parse_toml_entries "$local_file")
    remote_entries=$(parse_toml_entries "$remote_file")

    while IFS=$'\t' read -r sec key raw_line; do
        [[ -z "$key" ]] && continue
        local rval lline lval
        rval=$(echo "$raw_line" | sed 's/^[ \t]*//' | sed 's/[ \t]*$//')
        lline=$(printf '%s\n' "$local_entries" | awk -F'\t' -v s="$sec" -v k="$key" '$1==s && $2==k {print $3}')
        if [[ -z "$lline" ]]; then
            return 1
        fi
        lval=$(echo "$lline" | sed 's/^[ \t]*//' | sed 's/[ \t]*$//')
        if [[ "$lval" != "$rval" ]]; then
            return 1
        fi
    done <<< "$remote_entries"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# extract_module <toml-line>
# Extracts the module coordinate (e.g. "com.google.ads.mediation:applovin")
# from a TOML library entry line. Handles both { module = "..." } and
# { group = "...", name = "..." } syntax.
# ──────────────────────────────────────────────────────────────────────────────
extract_module() {
    local line="$1"
    if [[ "$line" =~ module[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        echo "${BASH_REMATCH[1]}"; return
    fi
    local g="" n=""
    if [[ "$line" =~ group[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then g="${BASH_REMATCH[1]}"; fi
    if [[ "$line" =~ name[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then n="${BASH_REMATCH[1]}"; fi
    if [[ -n "$g" && -n "$n" ]]; then echo "${g}:${n}"; return; fi
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# merge_catalog <local-file> <remote-file> <output-file>
# Merges remote entries into local: override matching keys, append new ones.
# Local-only entries are preserved.
# Entries whose module coordinate already exists in remote are removed
# (even if the key name differs), preventing duplicates.
# ──────────────────────────────────────────────────────────────────────────────
merge_catalog() {
    local local_file="$1" remote_file="$2" output_file="$3"

    local remote_entries
    remote_entries=$(parse_toml_entries "$remote_file")

    local remote_modules=""
    while IFS=$'\t' read -r sec key raw_line; do
        [[ -z "$key" ]] && continue
        if [[ "$sec" == "libraries" ]]; then
            local mod
            mod=$(extract_module "$raw_line")
            if [[ -n "$mod" ]]; then
                remote_modules="${remote_modules}${mod}"$'\n'
            fi
        fi
    done <<< "$remote_entries"

    local VREFS_TMP REMOTE_DATA_TMP REMOTE_MODS_TMP
    VREFS_TMP=$(mktemp)
    REMOTE_DATA_TMP=$(mktemp)
    REMOTE_MODS_TMP=$(mktemp)
    printf '%s\n' "$remote_entries" > "$REMOTE_DATA_TMP"
    printf '%s\n' "$remote_modules" > "$REMOTE_MODS_TMP"

    awk -v remote_data_file="$REMOTE_DATA_TMP" -v remote_mods_file="$REMOTE_MODS_TMP" -v vrefs_file="$VREFS_TMP" '
    function extract_quoted(line, key,    pos, tmp) {
        pos = index(line, key)
        if (pos == 0) return ""
        tmp = substr(line, pos + length(key))
        sub(/^[^"]*"/, "", tmp)
        sub(/".*$/, "", tmp)
        return tmp
    }
    function extract_mod(line,    g, n) {
        if (index(line, "module") > 0) {
            g = extract_quoted(line, "module")
            if (g != "") return g
        }
        g = ""; n = ""
        if (index(line, "group") > 0) g = extract_quoted(line, "group")
        if (index(line, "name") > 0)  n = extract_quoted(line, "name")
        if (g != "" && n != "") return g ":" n
        return ""
    }
    function extract_version_ref(line) {
        if (index(line, "version.ref") == 0) return ""
        return extract_quoted(line, "version.ref")
    }

    BEGIN {
        while ((getline rline < remote_data_file) > 0) {
            n_parts = split(rline, parts, "\t")
            if (n_parts >= 3) {
                s = parts[1]; k = parts[2]
                raw = parts[3]
                for (j = 4; j <= n_parts; j++) raw = raw "\t" parts[j]
                remote_key = s SUBSEP k
                remote_val[remote_key] = raw
                if (!(s in sec_count)) sec_count[s] = 0
                sec_count[s]++
                sec_keys[s, sec_count[s]] = k
            }
        }
        close(remote_data_file)

        while ((getline mline < remote_mods_file) > 0) {
            if (mline != "") remote_mod_set[mline] = 1
        }
        close(remote_mods_file)

        current_sec = ""
        tail_count = 0
    }

    /^[[:space:]]*\[/ {
        line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (substr(line, 1, 1) == "[") {
            new_sec = line; sub(/^\[/, "", new_sec); sub(/\].*$/, "", new_sec)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", new_sec)

            if (current_sec != "" && current_sec in sec_count) {
                hdr = 0
                for (ri = 1; ri <= sec_count[current_sec]; ri++) {
                    rk = sec_keys[current_sec, ri]
                    rkey = current_sec SUBSEP rk
                    if (!(rkey in written)) {
                        if (!hdr) { print ""; print "# ── Managed by catalog (do not edit below) ──"; hdr = 1 }
                        print remote_val[rkey]
                        written[rkey] = 1
                    }
                }
            }
            for (ti = 1; ti <= tail_count; ti++) print tail_buf[ti]
            tail_count = 0

            current_sec = new_sec
            local_sections[current_sec] = 1
            print $0
            next
        }
    }

    current_sec != "" {
        line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line != "" && substr(line, 1, 1) != "#") {
            eq = index(line, "=")
            if (eq > 0) {
                key = substr(line, 1, eq - 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                if (key != "") {
                    rkey = current_sec SUBSEP key
                    if (rkey in remote_val) {
                        tail_count = 0
                    } else if (current_sec == "libraries") {
                        local_mod = extract_mod(line)
                        if (local_mod != "" && (local_mod in remote_mod_set)) {
                            vref = extract_version_ref(line)
                            if (vref != "" && vrefs_file != "") {
                                print vref > vrefs_file
                            }
                            tail_count = 0
                        } else {
                            for (ti = 1; ti <= tail_count; ti++) print tail_buf[ti]
                            tail_count = 0
                            print $0
                        }
                    } else {
                        for (ti = 1; ti <= tail_count; ti++) print tail_buf[ti]
                        tail_count = 0
                        print $0
                    }
                    next
                }
            }
        }
        tail_count++
        tail_buf[tail_count] = $0
        next
    }

    { print }

    END {
        if (current_sec != "" && current_sec in sec_count) {
            hdr = 0
            for (ri = 1; ri <= sec_count[current_sec]; ri++) {
                rk = sec_keys[current_sec, ri]
                rkey = current_sec SUBSEP rk
                if (!(rkey in written)) {
                    if (!hdr) { print ""; print "# ── Managed by catalog (do not edit below) ──"; hdr = 1 }
                    print remote_val[rkey]
                    written[rkey] = 1
                }
            }
        }
        for (ti = 1; ti <= tail_count; ti++) print tail_buf[ti]

        for (s in sec_count) {
            if (!(s in local_sections)) {
                print ""
                print "[" s "]"
                print "# ── Managed by catalog (do not edit below) ──"
                for (ri = 1; ri <= sec_count[s]; ri++) {
                    rk = sec_keys[s, ri]
                    print remote_val[s SUBSEP rk]
                }
            }
        }
    }
    ' "$local_file" > "$output_file"

    if [[ -s "$VREFS_TMP" ]]; then
        local vref tmp_out
        while IFS= read -r vref; do
            [[ -z "$vref" ]] && continue
            if ! grep -qE "version\\.ref[[:space:]]*=[[:space:]]*\"${vref}\"" "$output_file"; then
                tmp_out=$(mktemp)
                grep -vE "^[[:space:]]*${vref}[[:space:]]*=" "$output_file" > "$tmp_out"
                mv "$tmp_out" "$output_file"
            fi
        done < "$VREFS_TMP"
    fi
    rm -f "$VREFS_TMP" "$REMOTE_DATA_TMP" "$REMOTE_MODS_TMP"
}

if ! fetch_to_file "$URL" "$TMP_FILE"; then
    echo "[CatalogSync] [WARN] Cannot reach remote catalog: fetch failed."
    echo "[CatalogSync] Using existing local file (if present)."
    exit 0
fi

echo "[CatalogSync] [SYNC] Updating catalog..."

mkdir -p "$(dirname "$LOCAL_PATH")"

if [[ -f "$LOCAL_PATH" ]]; then
    merge_catalog "$LOCAL_PATH" "$TMP_FILE" "$MERGE_TMP"
    cp "$MERGE_TMP" "$LOCAL_PATH"
else
    cp "$TMP_FILE" "$LOCAL_PATH"
fi

echo "[CatalogSync] [OK] Catalog saved -> $LOCAL_PATH"
echo "[CatalogSync] [INFO] Re-sync the project / restart the build to apply new versions."
