#!/usr/bin/env bash
# Preflight every cluster in clusters.conf. Classifies the failure, because
# "cannot connect" and "connected but rejected" need different fixes.
set -uo pipefail
SCRIPT_VERSION="${SCRIPT_VERSION:-v0.1.0}"
CONF="${1:-clusters.conf}"
echo "preflight.sh version=$SCRIPT_VERSION" >&2
printf 'cluster_id\tenv\tresult\tdetail\n'
while IFS=$'\t' read -r CID CENV _rest; do
  case "${CID:-}" in ''|\#*) continue ;; esac
  CENV="$(printf '%s' "${CENV:-}" | tr -d ' \r')"
  ERR="$(temporal --env "$CENV" operator cluster describe --output json 2>&1 >/tmp/.pf.$$ || true)"
  NAME="$(jq -r '.clusterName // empty' </tmp/.pf.$$ 2>/dev/null)"
  if [ -n "$NAME" ]; then
    RESULT="OK"; DETAIL="$NAME"
  else
    case "$ERR" in
      *"certificate required"*|*"tls:"*|*"x509"*)
        RESULT="AUTH FAILED"; DETAIL="server wants mTLS - add tls-cert-path, tls-key-path, tls-ca-path to env '$CENV'" ;;
      *"connection refused"*)
        RESULT="UNREACHABLE"; DETAIL="nothing listening - check the address or start the port-forward" ;;
      *"server preface"*)
        RESULT="HALF OPEN"; DETAIL="TCP accepted but no gRPC - wrong port, or a stale forward/proxy" ;;
      *"UNAUTHENTICATED"*|*"PERMISSION_DENIED"*)
        RESULT="AUTH FAILED"; DETAIL="credentials rejected" ;;
      *) RESULT="FAILED"; DETAIL="$(printf '%s' "$ERR" | head -1 | cut -c1-90)" ;;
    esac
  fi
  rm -f /tmp/.pf.$$
  printf '%s\t%s\t%s\t%s\n' "$CID" "$CENV" "$RESULT" "$DETAIL"
done < "$CONF"
