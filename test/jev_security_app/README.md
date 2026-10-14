# Jev security triage fixture

This deliberately vulnerable TypeScript app exercises security-review cases
that have been stochastic or easy to miss:

1. markdown-to-HTML XSS through an attacker-selected response content type;
2. a `javascript:` markdown link built from a query parameter;
3. cookie data reflected through JSON and assigned to `innerHTML`;
4. SQL injection hidden behind small query-building helpers;
5. SSRF hidden behind URL-normalization helpers;
6. path traversal after a double URL decode;
7. an IDOR update that does not constrain the record by the current user.

`safe.ts` contains parameterized SQL, `textContent`, and a fixed-origin fetch as
negative controls. The fixture is test data and must never be deployed.
