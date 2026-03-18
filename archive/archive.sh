#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
	cat <<'EOF'
Usage:
	ollama.sh archive <model> [archive-file]
	ollama.sh restore <archive-file> [target-model-store]
	ollama.sh help

Examples:
	ollama.sh archive llama3.2
	ollama.sh archive llama3.2 /tmp/llama3.2-archive.tgz
	sudo ollama.sh restore /tmp/llama3.2-archive.tgz
	sudo ollama.sh restore /tmp/llama3.2-archive.tgz /usr/share/ollama/.ollama/models

Notes:
	- The archive command copies the model manifest and every blob digest referenced by it.
	- The restore command extracts those files into an Ollama model store on Ubuntu.
	- After restore, verify with: ollama list
EOF
}

log() {
	printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

default_store_path() {
	if [ -n "${OLLAMA_MODELS:-}" ]; then
		printf '%s\n' "$OLLAMA_MODELS"
		return
	fi

	if [ -d "/usr/share/ollama/.ollama/models" ]; then
		printf '%s\n' "/usr/share/ollama/.ollama/models"
		return
	fi

	if [ -d "/var/lib/ollama/.ollama/models" ]; then
		printf '%s\n' "/var/lib/ollama/.ollama/models"
		return
	fi

	if [ -d "$HOME/.ollama/models" ]; then
		printf '%s\n' "$HOME/.ollama/models"
		return
	fi

	if command -v getent >/dev/null 2>&1 && getent passwd ollama >/dev/null 2>&1; then
		printf '%s\n' "/usr/share/ollama/.ollama/models"
		return
	fi

	printf '%s\n' "$HOME/.ollama/models"
}

resolve_store_path() {
	local requested="${1:-}"
	local store

	if [ -n "$requested" ]; then
		store="$requested"
	else
		store="$(default_store_path)"
	fi

	printf '%s\n' "$store"
}

detect_service_owner() {
	local service_user

	if command -v systemctl >/dev/null 2>&1; then
		service_user="$(systemctl show ollama --property=User --value 2>/dev/null | tr -d '[:space:]' || true)"
		if [ -n "$service_user" ]; then
			printf '%s\n' "$service_user"
			return
		fi
	fi

	if command -v getent >/dev/null 2>&1 && getent passwd ollama >/dev/null 2>&1; then
		printf '%s\n' "ollama"
		return
	fi

	return 1
}

normalize_model_ref() {
	local raw="$1"
	local host="registry.ollama.ai"
	local namespace="library"
	local remainder="$raw"
	local repo tag

	if [[ "$remainder" == *'/'* ]]; then
		local first_segment="${remainder%%/*}"
		if [[ "$first_segment" == *.* ]] || [[ "$first_segment" == *:* ]] || [[ "$first_segment" == "localhost" ]]; then
			host="$first_segment"
			remainder="${remainder#*/}"
		fi
	fi

	repo="$remainder"
	tag="latest"

	if [[ "$repo" == *':'* ]]; then
		tag="${repo##*:}"
		repo="${repo%:*}"
	fi

	if [[ "$repo" == */* ]]; then
		namespace="${repo%%/*}"
		repo="${repo#*/}"
	fi

	[ -n "$repo" ] || die "Invalid model reference: $raw"
	[ -n "$tag" ] || die "Invalid model tag: $raw"

	printf '%s\n' "$host" "$namespace" "$repo" "$tag"
}

manifest_relpath() {
	local model_ref="$1"
	local parts host namespace repo tag

	mapfile -t parts < <(normalize_model_ref "$model_ref")
	host="${parts[0]}"
	namespace="${parts[1]}"
	repo="${parts[2]}"
	tag="${parts[3]}"

	printf 'manifests/%s/%s/%s/%s\n' "$host" "$namespace" "$repo" "$tag"
}

find_manifest_path() {
	local store="$1"
	local model_ref="$2"
	local relpath expected repo tag candidate
	local parts=()

	relpath="$(manifest_relpath "$model_ref")"
	expected="$store/$relpath"
	if [ -f "$expected" ]; then
		printf '%s\n' "$expected"
		return
	fi

	mapfile -t parts < <(normalize_model_ref "$model_ref")
	repo="${parts[2]}"
	tag="${parts[3]}"

	candidate="$(find "$store/manifests" -type f 2>/dev/null | grep -E "/${repo//./\\.}/${tag//./\\.}$" | head -n 1 || true)"
	[ -n "$candidate" ] || die "Model manifest not found for '$model_ref' under $store"
	printf '%s\n' "$candidate"
}

extract_digests() {
	local manifest="$1"
	grep -oE '"digest"[[:space:]]*:[[:space:]]*"[^"]+"' "$manifest" | sed -E 's/.*"([^"]+)"/\1/' | sort -u
}

digest_to_blob_name() {
	local digest="$1"
	printf '%s\n' "${digest/:/-}"
}

archive_model() {
	local model_ref="$1"
	local archive_file="$2"
	local store manifest tmpdir stage_rel manifest_rel target_manifest blob_count digest blob_name blob_path

	require_cmd tar
	store="$(resolve_store_path "")"
	[ -d "$store" ] || die "Ollama model store not found: $store"

	manifest="$(find_manifest_path "$store" "$model_ref")"
	manifest_rel="${manifest#"$store/"}"

	tmpdir="$(mktemp -d)"
	trap 'rm -rf "$tmpdir"' EXIT

	mkdir -p "$tmpdir/$(dirname "$manifest_rel")" "$tmpdir/blobs"
	cp "$manifest" "$tmpdir/$manifest_rel"

	blob_count=0
	while IFS= read -r digest; do
		[ -n "$digest" ] || continue
		blob_name="$(digest_to_blob_name "$digest")"
		blob_path="$store/blobs/$blob_name"
		[ -f "$blob_path" ] || die "Referenced blob missing: $blob_path"
		cp "$blob_path" "$tmpdir/blobs/$blob_name"
		blob_count=$((blob_count + 1))
	done < <(extract_digests "$manifest")

	cat > "$tmpdir/ARCHIVE_INFO" <<EOF
MODEL_REF=$model_ref
SOURCE_STORE=$store
MANIFEST_RELATIVE_PATH=$manifest_rel
BLOB_COUNT=$blob_count
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

	tar -C "$tmpdir" -czf "$archive_file" ARCHIVE_INFO manifests blobs
	log "Archived $model_ref to $archive_file"
	log "Manifest: $manifest_rel"
	log "Blobs copied: $blob_count"
}

restore_model() {
	local archive_file="$1"
	local target_store="$2"
	local tmpdir owner_group root_dir service_user

	require_cmd tar
	[ -f "$archive_file" ] || die "Archive file not found: $archive_file"

	tmpdir="$(mktemp -d)"
	trap 'rm -rf "$tmpdir"' EXIT

	tar -C "$tmpdir" -xzf "$archive_file"
	[ -d "$tmpdir/manifests" ] || die "Archive is missing manifests/"
	[ -d "$tmpdir/blobs" ] || die "Archive is missing blobs/"

	mkdir -p "$target_store/manifests" "$target_store/blobs"

	cp -R "$tmpdir/manifests/." "$target_store/manifests/"
	cp -R "$tmpdir/blobs/." "$target_store/blobs/"

	root_dir="$(dirname "$target_store")"
	if [ "$(id -u)" -eq 0 ]; then
		service_user="$(detect_service_owner || true)"
		if [ -n "$service_user" ]; then
			chown -R "$service_user:$service_user" "$target_store"
		elif [ -d "$root_dir" ]; then
			owner_group="$(stat -c '%u:%g' "$root_dir" 2>/dev/null || true)"
			if [ -n "$owner_group" ]; then
				chown -R "$owner_group" "$target_store"
			fi
		fi
	fi

	if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files ollama.service >/dev/null 2>&1; then
		if [ "$(id -u)" -eq 0 ]; then
			systemctl restart ollama || true
			log "Restarted ollama service"
		else
			log "Restore completed. Restart ollama with: sudo systemctl restart ollama"
		fi
	fi

	log "Restored archive into $target_store"
	log "Verify with: ollama list"
}

main() {
	local command="${1:-help}"

	case "$command" in
		archive)
			local model_ref archive_file
			model_ref="${2:-}"
			[ -n "$model_ref" ] || die "Missing model reference. Example: $SCRIPT_NAME archive llama3.2"
			archive_file="${3:-}"
			if [ -z "$archive_file" ]; then
				archive_file="${model_ref//\//_}"
				archive_file="${archive_file//:/_}"
				archive_file="${archive_file}-archive.tgz"
			fi
			archive_model "$model_ref" "$archive_file"
			;;
		restore)
			local archive_file target_store
			archive_file="${2:-}"
			[ -n "$archive_file" ] || die "Missing archive file. Example: $SCRIPT_NAME restore llama3.2-archive.tgz"
			target_store="$(resolve_store_path "${3:-}")"
			restore_model "$archive_file" "$target_store"
			;;
		help|-h|--help)
			usage
			;;
		*)
			die "Unknown command: $command"
			;;
	esac
}

main "$@"
