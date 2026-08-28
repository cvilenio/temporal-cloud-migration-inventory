#!/usr/bin/env bash
# Preflight every cluster in clusters.conf. Classifies the failure, because
# "cannot connect" and "connected but rejected" need different fixes.
set -uo pipefail
SCRIPT_VERSION="${SCRIPT_VERSION:-v0.1.0}"
CONF="${1:-clusters.conf}"
echo "preflight.sh version=$SCRIPT_VERSION" >&2
printf 'cluster_id\tenv\tresult\tdetail\n'
PF_TMP="$(mktemp)"
trap 'rm -f "$PF_TMP"' EXIT
# `|| [ -n "$CID" ]` so a final line with no trailing newline is not dropped.
while IFS=$'\t' read -r CID CENV _rest || [ -n "${CID:-}" ]; do
  case "${CID:-}" in ''|\#*) CID=""; continue ;; esac
  CENV="$(printf '%s' "${CENV:-}" | tr -d ' \r')"
  ERR="$(temporal --env "$CENV" operator cluster describe --output json 2>&1 >"$PF_TMP" || true)"
  NAME="$(jq -r '.clusterName // empty' <"$PF_TMP" 2>/dev/null)"
  if [ -n "$NAME" ]; then
    RESULT="OK"; DETAIL="$NAME"
  else
    case "$ERR" in
      *"certificate required"*|*"tls:"*|*"x509"*)
        RESULT="AUTH FAILED"; DETAIL="server wants mTLS - add tls-cert-path, tls-key-path, tls-ca-path to env '$CENV'" ;;
      *"connection refused"*)
        RESULT="UNREACHABLE"; DETAIL="nothing listening - check the address or start the port-forward" ;;
      *"server preface"*)
        RESULT="HALF OPEN"; DETAIL="TCP accepted but no gRPC - the frontend may require TLS (add tls-* keys to env $CENV), or wrong port / stale forward" ;;
      *"UNAUTHENTICATED"*|*"PERMISSION_DENIED"*)
        RESULT="AUTH FAILED"; DETAIL="credentials rejected" ;;
      *) RESULT="FAILED"; DETAIL="$(printf '%s' "$ERR" | head -1 | cut -c1-90)" ;;
    esac
  fi
  printf '%s\t%s\t%s\t%s\n' "$CID" "$CENV" "$RESULT" "$DETAIL"
done < "$CONF"
