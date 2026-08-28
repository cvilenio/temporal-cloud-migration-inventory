#!/usr/bin/env bash
# Preflight every cluster in clusters.conf. Classifies the failure, because
# "cannot connect" and "connected but rejected" need different fixes.
set -uo pipefail
SCRIPT_VERSION="${SCRIPT_VERSION:-v0.1.2}"
echo "preflight.sh version=$SCRIPT_VERSION" >&2
case "${1:-}" in
  -h|--help) sed -n '2,3p' "$0"; echo "usage: $0 [clusters.conf]"; exit 0 ;;
esac
CONF="${1:-clusters.conf}"
[ -r "$CONF" ] || { echo "cannot read $CONF" >&2; exit 2; }
printf 'cluster_id\tenv\tresult\tdetail\n'
PF_TMP="$(mktemp)"
trap 'rm -f "$PF_TMP"' EXIT
# `|| [ -n "$CID" ]` so a final line with no trailing newline is not dropped.
while IFS=$'\t' read -r CID CENV _rest || [ -n "${CID:-}" ]; do
  case "${CID:-}" in ''|\#*) CID=""; continue ;; esac
  CENV="$(printf '%s' "${CENV:-}" | tr -d ' \r')"
  if [ -z "$CENV" ]; then
    # $CID holds the whole raw line when the columns were space-separated, so
    # emit a safe first field and put the raw text in the detail column.
    _first="$(printf '%s' "$CID" | awk '{print $1}')"
    printf '%s\t\tSKIPPED\tno TEMPORAL_ENV in %s - needs a real tab between the columns; line was: %s\n' \
      "$_first" "$CONF" "$(printf '%s' "$CID" | tr '\t' ' ')"
    CID=""; continue
  fi
  ERR="$(temporal --env "$CENV" operator cluster describe --output json 2>&1 >"$PF_TMP" || true)"
  NAME="$(jq -r '.clusterName // empty' <"$PF_TMP" 2>/dev/null)"
  if [ -n "$NAME" ]; then
    RESULT="OK"; DETAIL="$NAME"
  else
    case "$ERR" in
      *"certificate is valid for"*|*"IP SANs"*|*"doesn't contain any IP SANs"*)
        RESULT="AUTH FAILED"; DETAIL="server cert does not cover this address - set tls-server-name on env '$CENV' to a name in the cert (an IP or a port-forward address is never in the cert)" ;;
      *"unknown authority"*|*"verification failure"*)
        RESULT="AUTH FAILED"; DETAIL="CA rejected the server cert - tls-ca-path on env '$CENV' is wrong or stale (check for a re-issued CA)" ;;
      *"certificate required"*)
        RESULT="AUTH FAILED"; DETAIL="server wants a client certificate - add tls-cert-path and tls-key-path to env '$CENV'" ;;
      *"tls:"*|*"x509"*)
        RESULT="AUTH FAILED"; DETAIL="TLS handshake failed - $(printf '%s' "$ERR" | tr '\n' ' ' | cut -c1-90)" ;;
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
