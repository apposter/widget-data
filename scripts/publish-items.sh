#!/usr/bin/env bash
#
# publish-items.sh
# widget-data 레포의 워치페이스 데이터를 운영팀 CSV 기준으로 갱신한다.
#
# - items.csv를 기준으로 누락된 워치페이스 JSON/PNG를 다운로드
# - index.json을 categories.csv + items.csv로 전체 재생성
# - idempotent: 같은 입력으로 여러 번 실행해도 동일 결과
#
# 사용법:
#   ./publish-items.sh                  # 처리만
#   ./publish-items.sh --force          # 동일 id+v여도 강제 재다운로드
#   ./publish-items.sh --commit         # 처리 후 자동 git commit
#   ./publish-items.sh --commit --push  # commit + push

set -uo pipefail

# ----------------------------------------------------------------------
# 옵션 파싱
# ----------------------------------------------------------------------
FORCE=false
COMMIT=false
PUSH=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)  FORCE=true ;;
        --commit) COMMIT=true ;;
        --push)   PUSH=true ;;
        -h|--help)
            sed -n '2,17p' "$0"
            exit 0
            ;;
        *)
            echo "알 수 없는 옵션: $1"
            exit 1
            ;;
    esac
    shift
done

# ----------------------------------------------------------------------
# 경로 / 상수
# ----------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CATEGORIES_CSV="$REPO_ROOT/categories.csv"
ITEMS_CSV="$SCRIPT_DIR/items.csv"
ITEMS_DIR="$REPO_ROOT/items"
INDEX_JSON="$REPO_ROOT/index.json"

API_NEW="https://lapi.timeflik.com"
API_OLD="https://web.timeflik.com"

REQUIRED_CATEGORIES_COLS=(id name nameKo order)
REQUIRED_ITEMS_COLS=(id name category)        # v, tags는 선택

# CSV 헤더에서 특정 컬럼명의 1-based 인덱스를 출력. 없으면 0.
csv_col_idx() {
    local header="$1" col="$2"
    awk -F, -v col="$col" '
        NR == 1 {
            for (i = 1; i <= NF; i++) if ($i == col) { print i; exit }
            print 0
        }
    ' <<< "$header"
}

# 필수 컬럼들이 모두 있는지 검증. 누락 컬럼 있으면 에러 메시지 출력 + 1 반환.
validate_required_cols() {
    local label="$1" header="$2"
    shift 2
    local missing=""
    for col in "$@"; do
        if [[ "$(csv_col_idx "$header" "$col")" == "0" ]]; then
            missing+="${col} "
        fi
    done
    if [[ -n "$missing" ]]; then
        echo "오류: ${label}에 필수 컬럼 누락: ${missing% }"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------
# 의존성 / 파일 확인
# ----------------------------------------------------------------------
for cmd in jq curl awk sort comm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "오류: $cmd가 설치되어 있지 않습니다."
        exit 1
    fi
done

[[ -f "$CATEGORIES_CSV" ]] || { echo "오류: $CATEGORIES_CSV 없음"; exit 1; }
[[ -f "$ITEMS_CSV" ]]      || { echo "오류: $ITEMS_CSV 없음"; exit 1; }

# ----------------------------------------------------------------------
# 헤더 검증 (컬럼 순서 무관, 추가 컬럼 허용)
# ----------------------------------------------------------------------
cat_header=$(head -n 1 "$CATEGORIES_CSV" | tr -d '\r')
items_header=$(head -n 1 "$ITEMS_CSV" | tr -d '\r')

validate_required_cols "categories.csv" "$cat_header" "${REQUIRED_CATEGORIES_COLS[@]}" || exit 1
validate_required_cols "items.csv" "$items_header" "${REQUIRED_ITEMS_COLS[@]}" || exit 1

# 각 컬럼 인덱스 (1-based)
CAT_IDX_ID=$(csv_col_idx "$cat_header" "id")
CAT_IDX_NAME=$(csv_col_idx "$cat_header" "name")
CAT_IDX_NAMEKO=$(csv_col_idx "$cat_header" "nameKo")
CAT_IDX_ORDER=$(csv_col_idx "$cat_header" "order")

ITEMS_IDX_ID=$(csv_col_idx "$items_header" "id")
ITEMS_IDX_NAME=$(csv_col_idx "$items_header" "name")
ITEMS_IDX_CATEGORY=$(csv_col_idx "$items_header" "category")
ITEMS_IDX_V=$(csv_col_idx "$items_header" "v")
ITEMS_IDX_TAGS=$(csv_col_idx "$items_header" "tags")

# ----------------------------------------------------------------------
# 임시 파일 (모두 한 번에 등록)
# ----------------------------------------------------------------------
items_tmp=$(mktemp)
new_items_file=$(mktemp)
new_ids_file=$(mktemp)
ver_update_file=$(mktemp)
prev_ids_file=$(mktemp)
current_ids_file=$(mktemp)
meta_changes_file=$(mktemp)
trap 'rm -f "$items_tmp" "$new_items_file" "$new_ids_file" "$ver_update_file" "$prev_ids_file" "$current_ids_file" "$meta_changes_file"' EXIT

# 카테고리 ID 집합
valid_categories=$(tail -n +2 "$CATEGORIES_CSV" | tr -d '\r' | awk -F, -v i="$CAT_IDX_ID" '$i != "" {print $i}')

# items 정제 + 표준 순서(id,name,category,v,tags)로 재배열
# 운영팀이 컬럼 순서를 바꾸거나 추가 컬럼을 두어도 일관된 5컬럼 CSV로 정규화한다.
# v, tags 컬럼이 헤더에 아예 없으면(인덱스 0) 빈 값으로 출력 → 이후 기본값(v=1, tags=[]) 적용.
tail -n +2 "$ITEMS_CSV" | tr -d '\r' | awk 'NF' \
    | awk -F, -v OFS=, \
        -v i_id="$ITEMS_IDX_ID" \
        -v i_name="$ITEMS_IDX_NAME" \
        -v i_cat="$ITEMS_IDX_CATEGORY" \
        -v i_v="$ITEMS_IDX_V" \
        -v i_tags="$ITEMS_IDX_TAGS" \
        '{
            v_out = (i_v == 0 ? "" : $i_v)
            tags_out = (i_tags == 0 ? "" : $i_tags)
            print $i_id, $i_name, $i_cat, v_out, tags_out
        }' > "$items_tmp"

# ----------------------------------------------------------------------
# 입력 검증
# ----------------------------------------------------------------------
errors=0

# 중복 id
duplicates=$(awk -F, '$1 != "" {print $1}' "$items_tmp" | sort | uniq -d)
if [[ -n "$duplicates" ]]; then
    echo "오류: 중복 id"
    echo "$duplicates" | sed 's/^/  - /'
    errors=$((errors + 1))
fi

# 라인별 검증 (필수값, 카테고리, v)
validation_output=$(awk -F, -v cats="$valid_categories" '
    BEGIN {
        n = split(cats, arr, "\n")
        for (i = 1; i <= n; i++) valid[arr[i]] = 1
        err = 0
    }
    {
        line = NR + 1
        id = $1; name = $2; category = $3; v = $4
        if (id == "")       { print "  [라인 " line "] id 누락"; err++; next }
        if (name == "")     { print "  [라인 " line ", id=" id "] name 누락"; err++ }
        if (category == "") { print "  [라인 " line ", id=" id "] category 누락"; err++ }
        if (category != "" && !(category in valid)) {
            print "  [라인 " line ", id=" id "] 알 수 없는 category: " category; err++
        }
        if (v != "" && v !~ /^[0-9]+$/) {
            print "  [라인 " line ", id=" id "] v는 숫자여야 함: " v; err++
        }
    }
    END { exit err > 0 ? 1 : 0 }
' "$items_tmp")
if [[ -n "$validation_output" ]]; then
    echo "오류: 라인 검증 실패"
    echo "$validation_output"
    errors=$((errors + 1))
fi

if [[ $errors -gt 0 ]]; then
    echo ""
    echo "검증 실패. 중단합니다."
    exit 1
fi

# ----------------------------------------------------------------------
# 이전 index.json 로드
# ----------------------------------------------------------------------
if [[ -s "$INDEX_JSON" ]]; then
    prev_items=$(jq -c '.items // []' "$INDEX_JSON" 2>/dev/null || echo "[]")
else
    prev_items="[]"
fi

# ----------------------------------------------------------------------
# 다운로드 + 신규 items 배열 빌드
# ----------------------------------------------------------------------
mkdir -p "$ITEMS_DIR"

new_count=0
ver_update_count=0
skip_count=0
fail_count=0

while IFS=, read -r id name category v tags; do
    [[ -z "$id" ]] && continue
    [[ -z "$v" ]] && v=1

    target_dir="$ITEMS_DIR/$id"
    target_json="$target_dir/v${v}.json"
    target_png="$target_dir/v${v}.png"

    if [[ -f "$target_json" && -f "$target_png" && "$FORCE" != true ]]; then
        skip_count=$((skip_count + 1))
    else
        # 기존에 다른 v가 있었는지 (버전 갱신 판별)
        prev_v=""
        if [[ -d "$target_dir" ]]; then
            prev_v=$(ls "$target_dir" 2>/dev/null \
                | grep -oE '^v[0-9]+\.json$' \
                | sed -E 's/^v([0-9]+)\.json$/\1/' \
                | sort -n | tail -n 1 || true)
        fi

        echo "[$id] v${v} 다운로드 중..."
        mkdir -p "$target_dir"

        # JSON: 신규 API에서 version 확인 후 분기
        new_json_url="$API_NEW/api/watches/$id?version=2"
        tmp_json=$(curl -sf "$new_json_url" || true)
        if [[ -z "$tmp_json" ]]; then
            echo "  ✗ JSON 다운로드 실패 (신규 API)"
            fail_count=$((fail_count + 1))
            continue
        fi

        api_version=$(echo "$tmp_json" | jq -r '.version // 0')

        if [[ "$api_version" =~ ^[0-9]+$ ]] && [[ "$api_version" -ge 4 ]]; then
            echo "$tmp_json" > "$target_json"
        else
            old_json_url="$API_OLD/api/watches/$id?resourceType=base64"
            if ! curl -sf "$old_json_url" -o "$target_json"; then
                echo "  ✗ JSON 다운로드 실패 (구 API)"
                fail_count=$((fail_count + 1))
                continue
            fi
        fi

        # PNG 다운로드
        png_url="$API_NEW/watches/$id/preview?updatedAt=$(date +%s)000"
        if ! curl -sfL "$png_url" -o "$target_png"; then
            echo "  ✗ PNG 다운로드 실패"
            rm -f "$target_json"
            fail_count=$((fail_count + 1))
            continue
        fi

        # 신규 vs 버전 갱신 분류
        if [[ -n "$prev_v" && "$prev_v" != "$v" ]]; then
            ver_update_count=$((ver_update_count + 1))
            echo "${id} v${prev_v}→v${v}" >> "$ver_update_file"
        else
            new_count=$((new_count + 1))
            echo "${id} v${v}" >> "$new_ids_file"
        fi
    fi

    # tags 배열 (콜론 구분)
    if [[ -z "$tags" ]]; then
        tags_json="[]"
    else
        tags_json=$(printf '%s' "$tags" | tr ':' '\n' | jq -R . | jq -s -c .)
    fi

    jq -nc \
        --arg id "$id" \
        --arg name "$name" \
        --argjson v "$v" \
        --arg category "$category" \
        --argjson tags "$tags_json" \
        '{id: $id, name: $name, v: $v, category: $category, tags: $tags}' \
        >> "$new_items_file"
done < "$items_tmp"

# ----------------------------------------------------------------------
# index.json 생성
# ----------------------------------------------------------------------
categories_json=$(tail -n +2 "$CATEGORIES_CSV" | tr -d '\r' | awk -F, \
    -v i_id="$CAT_IDX_ID" \
    -v i_name="$CAT_IDX_NAME" \
    -v i_nameko="$CAT_IDX_NAMEKO" \
    -v i_order="$CAT_IDX_ORDER" '
    $i_id != "" {
        printf "{\"id\":\"%s\",\"name\":\"%s\",\"nameKo\":\"%s\",\"order\":%s}\n", $i_id, $i_name, $i_nameko, $i_order
    }
' | jq -s -c '.')

items_array=$(jq -s -c '.' "$new_items_file")

jq -n \
    --argjson categories "$categories_json" \
    --argjson items "$items_array" \
    '{categories: $categories, items: $items}' > "$INDEX_JSON"

# ----------------------------------------------------------------------
# 인덱스에서 제외된 ID
# ----------------------------------------------------------------------
echo "$prev_items" | jq -r '.[].id' | sort -u > "$prev_ids_file"
awk -F, '{print $1}' "$items_tmp" | sort -u > "$current_ids_file"

excluded_list=$(comm -23 "$prev_ids_file" "$current_ids_file" || true)
excluded_count=0
[[ -n "$excluded_list" ]] && excluded_count=$(echo "$excluded_list" | wc -l | tr -d ' ')

# ----------------------------------------------------------------------
# 카테고리/메타 변경 감지 (같은 v인데 category 또는 tags가 바뀐 경우)
# ----------------------------------------------------------------------
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id=$(echo "$entry" | jq -r '.id')
    new_v=$(echo "$entry" | jq -r '.v')
    new_cat=$(echo "$entry" | jq -r '.category')
    new_tags=$(echo "$entry" | jq -c '.tags')

    prev_entry=$(echo "$prev_items" | jq -c --arg id "$id" '.[] | select(.id == $id)' | head -n 1)
    [[ -z "$prev_entry" ]] && continue

    prev_v=$(echo "$prev_entry" | jq -r '.v')
    prev_cat=$(echo "$prev_entry" | jq -r '.category')
    prev_tags=$(echo "$prev_entry" | jq -c '.tags // []')

    if [[ "$new_v" == "$prev_v" ]]; then
        parts=""
        [[ "$new_cat" != "$prev_cat" ]]   && parts+="category ${prev_cat}→${new_cat} "
        [[ "$new_tags" != "$prev_tags" ]] && parts+="tags 변경"
        if [[ -n "$parts" ]]; then
            echo "${id}: ${parts}" >> "$meta_changes_file"
        fi
    fi
done < "$new_items_file"

meta_count=0
[[ -s "$meta_changes_file" ]] && meta_count=$(wc -l < "$meta_changes_file" | tr -d ' ')

# ----------------------------------------------------------------------
# 요약 출력
# ----------------------------------------------------------------------
echo ""
echo "========================================"
echo "요약:"
echo "  신규 다운로드:        ${new_count}개"
[[ -s "$new_ids_file" ]] && sed 's/^/    - /' "$new_ids_file"
echo "  버전 갱신:            ${ver_update_count}개"
[[ -s "$ver_update_file" ]] && sed 's/^/    - /' "$ver_update_file"
echo "  스킵(기존):           ${skip_count}개"
echo "  카테고리/메타만 갱신: ${meta_count}개"
[[ -s "$meta_changes_file" ]] && sed 's/^/    - /' "$meta_changes_file"
echo "  인덱스에서 제외:      ${excluded_count}개"
[[ -n "$excluded_list" ]] && echo "$excluded_list" | sed 's/^/    - /'
if [[ $fail_count -gt 0 ]]; then
    echo "  다운로드 실패:        ${fail_count}개"
fi
echo "========================================"

# ----------------------------------------------------------------------
# git 작업
# ----------------------------------------------------------------------
if [[ "$COMMIT" == true ]]; then
    cd "$REPO_ROOT"
    git add categories.csv scripts/items.csv items/ index.json
    if git diff --cached --quiet; then
        echo ""
        echo "변경사항 없음. commit 생략."
    else
        commit_msg="publish items: +${new_count} ⬆${ver_update_count} -${excluded_count}"
        git commit -m "$commit_msg"
        echo ""
        echo "✓ commit: ${commit_msg}"
        if [[ "$PUSH" == true ]]; then
            git push
            echo "✓ push 완료"
        fi
    fi
fi

echo ""
echo "완료."
