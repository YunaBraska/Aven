# Jira REST boundary

Determine deployment and credential type from trusted metadata or a bounded authenticated discovery
request. Do not infer authentication from the word `token` or try one secret across unrelated hosts.

- Jira Cloud REST v3 is the default Cloud platform API. A user API token for a simple local script
  uses Basic authentication with the Atlassian account email and token; an account password does not.
- Cloud OAuth 2.0 uses a Bearer access token and the Atlassian API gateway path associated with its
  cloud ID and scopes. Do not treat a Cloud API token as a Bearer token.
- Jira Data Center personal access tokens use Bearer authentication. Use the instance's documented
  REST version, commonly v2 or `latest`; do not assume Cloud v3 behavior.

Validate identity with the appropriate `myself` or server-information endpoint before broader work.
Keep the configured origin as the destination boundary and reject redirects to another host when an
Authorization header is present.

Request only required fields. Follow the response's pagination fields rather than assuming a fixed
page size: `startAt`, `maxResults`, `total`, and `isLast` may vary or be absent, and a page may be
empty. Bound total pages and returned records.

The current credential broker authorizes an exact argument array. A different JQL, issue key, field
selection, or page argument is a different binding even when the connector is unchanged. Rebind from
a trusted source; do not pass changing request data through an unscoped file or environment value.

On HTTP 429, honor `Retry-After` and relevant rate-limit headers with bounded backoff and jitter.
Retry safe reads when useful. Do not automatically repeat issue creation, comments, transitions, or
other non-idempotent writes.

Authoritative references:

- https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro/
- https://developer.atlassian.com/cloud/jira/platform/basic-auth-for-rest-apis/
- https://developer.atlassian.com/cloud/jira/platform/security-overview/
- https://developer.atlassian.com/cloud/jira/platform/rate-limiting/
- https://confluence.atlassian.com/enterprise/using-personal-access-tokens-1026032365.html
