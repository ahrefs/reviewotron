let triage_text = function
  | Config_types.Injection ->
    ( "Does `annotated_diff` warrant dedicated injection analysis because changed code may let untrusted data alter a \
       database query, template expression, interpreter input, or another data-language expression?",
      "The changed code contains a plausible untrusted-data source and interpreter or query sink without clearly \
       adequate contextual parameterization.",
      "The changed code has no plausible injection path, or the only relevant values are constants or clearly use \
       adequate parameterization." )
  | Xss ->
    ( "Does `annotated_diff` warrant dedicated cross-site scripting analysis because changed code may carry untrusted \
       data into HTML, JavaScript, CSS, a browser-executable URL, markdown-rendered HTML, or a response that can later \
       reach one of those browser contexts? Consider multi-step flows, attacker-controlled content types, cookie or \
       JSON reflection, and javascript: links.",
      "The changed code contains a plausible untrusted-data source and browser-executable sink or intermediate \
       representation without clearly adequate context-specific sanitization.",
      "The changed code has no plausible browser-executable data flow, or all relevant data is clearly encoded or \
       sanitized for its eventual browser context." )
  | Command_injection ->
    ( "Does `annotated_diff` warrant dedicated command-injection analysis because changed code may let untrusted data \
       influence a shell command, process invocation, executable, or command argument?",
      "The changed code contains a plausible untrusted-data source and process or shell sink without clearly safe \
       argument handling.",
      "The changed code has no plausible command-execution path, or the command and arguments are fixed or safely \
       separated from untrusted input." )
  | Authn ->
    ( "Does `annotated_diff` warrant dedicated authentication analysis because it changes how identities, credentials, \
       sessions, passwords, API keys, OAuth flows, or tokens are created, checked, or trusted?",
      "The changed code affects an authentication boundary or may accept an identity or credential without every \
       required validation.",
      "The changed code does not affect authentication, or it preserves clearly complete credential and identity \
       validation." )
  | Authz ->
    ( "Does `annotated_diff` warrant dedicated authorization analysis because it changes access control, ownership \
       checks, roles, permissions, or a read or mutation selected by an untrusted resource identifier?",
      "The changed code affects who can perform an action or access a resource, with a plausible missing or weakened \
       permission or ownership check.",
      "The changed code does not affect authorization, or every affected action is clearly constrained by the required \
       permission and resource ownership checks." )
  | Ssrf ->
    ( "Does `annotated_diff` warrant dedicated server-side request forgery analysis because untrusted data may \
       influence the host, scheme, port, path, redirect, or destination of an outbound request?",
      "The changed code contains a plausible untrusted-data source and outbound network sink without a clearly \
       adequate destination allowlist and redirect policy.",
      "The changed code has no plausible attacker-influenced outbound destination, or destinations are clearly and \
       completely constrained." )
  | Path_traversal ->
    ( "Does `annotated_diff` warrant dedicated path-traversal analysis because an untrusted path, filename, or archive \
       member may influence a file read, write, delete, extraction, or response?",
      "The changed code contains a plausible untrusted path component and filesystem sink without a clear \
       resolved-path containment check or safe basename or allowlist reduction.",
      "The changed code has no plausible attacker-controlled filesystem path, or every affected path is clearly \
       confined to the intended location." )
  | Policy_regression ->
    ( "Does `annotated_diff` warrant dedicated security-policy analysis because it may broaden privileges or weaken a \
       security control in IAM, RBAC, CI, deployment, TLS, sandbox, or operating-system configuration?",
      "The changed policy or configuration plausibly grants a broader capability or weakens a named security control.",
      "The change does not broaden privilege or weaken a security control, or it is clearly constrained to the same or \
       a narrower capability." )

let triage vuln_class : Decision_client.noul_question =
  let instructions, true_criteria, false_criteria = triage_text vuln_class in
  { instructions; true_criteria; false_criteria }

let candidate_supported : Decision_client.noul_question =
  {
    instructions =
      "Does `evidence` directly establish the security candidate in `candidate` as written, including the relevant \
       source or control change, security-sensitive sink or capability, missing or inadequate control, and concrete \
       current consequence, without any essential repository, platform, trust, reachability, or attacker fact absent \
       from the evidence?";
    true_criteria =
      "Every material required claim is directly supported and no unresolved assumption is needed for the current \
       security consequence.";
    false_criteria =
      "An essential claim is contradicted, controlled, speculative, or needs evidence or reasoning beyond what is \
       supplied.";
  }

let candidate_fatal_defect : Decision_client.noul_question =
  {
    instructions =
      "Does `candidate` have a fatal validation defect demonstrated by `evidence` or admitted in the candidate itself?";
    true_criteria =
      "A material description or blast-radius claim is contradicted; evidence shows the behavior is already adequately \
       controlled or is an expected minimally scoped prerequisite; or the candidate admits an essential exploit \
       mechanism is unverified or speculative.";
    false_criteria =
      "No such fatal defect is demonstrated. Missing context or uncertainty alone is not a fatal defect; answer false \
       when deeper reasoning or more evidence could still confirm the finding.";
  }

let source_constraint : Decision_client.noul_question =
  {
    instructions =
      "Does `evidence` directly contradict the candidate's claimed attacker-controlled source-to-sink influence by \
       showing that the exact value reaching the sink is constructed exclusively from fixed, trusted, typed, \
       UUID-derived, configured, or allowlisted components that prevent control of the security-sensitive component \
       named by the candidate?";
    true_criteria =
      "The evidence traces the value reaching the sink and shows the claimed attacker-controlled host, scheme, \
       command, path, principal, or equivalent security-sensitive component is fixed or constrained so the described \
       exploit cannot occur.";
    false_criteria =
      "The relevant component can still be attacker-controlled, or the evidence does not establish a complete \
       constraining provenance for the exact value reaching the sink.";
  }

let grouping_proposal : Decision_client.noul_question =
  {
    instructions =
      "Should `finding_a` and `finding_b` be sent together to a consolidation verifier because they plausibly arise \
       from the same causal defect or missing control and may share one repair? This judgment only retrieves possible \
       groups; it does not merge or suppress either confirmed finding.";
    true_criteria =
      "The findings plausibly share one causal source, source-of-truth policy, generated artifact, unsafe input, or \
       missing control such that one repair may resolve both. Include cases needing repository evidence to confirm the \
       relationship.";
    false_criteria =
      "The findings are independent defects or merely repeat a vulnerability pattern, principal, file, feature, or \
       review context without a plausible shared causal source or control.";
  }

let notification_grouping : Decision_client.noul_question =
  {
    instructions =
      "Should these independently confirmed findings appear under one review notification group while retaining both \
       complete findings, locations, impacts, and fixes?";
    true_criteria =
      "One accurate title and remediation plan can describe both findings because they belong to the same introduced \
       policy change, credential, input, unsafe operation, or repeated repair campaign. A source-of-truth finding and \
       manifestations in its generated artifacts are one group. A developer can resolve the group as one coherent \
       review action even when every affected site still needs its own edit.";
    false_criteria =
      "Grouping would mix different threat models, controls, assets, owners, urgency, or remediation plans. Keep \
       credential acquisition or authentication defects separate from post-authentication privilege escalation even \
       when they can form one attack chain. A shared vulnerability class, file, feature, attacker, or broad hardening \
       theme alone is insufficient.";
  }

let suggestion_defect : Decision_client.noul_question =
  {
    instructions =
      "Is `suggested_fix` mechanically defective or harmful as an actionable replacement for the validated finding, "
      ^ "given the exact reviewed file diff? Judge only the fix payload; do not reject the underlying finding.";
    true_criteria =
      "The payload is a no-op; contains literal escape text instead of required newlines; is prose rather than "
      ^ "applicable code; duplicates existing behavior; leaves the stated defect unchanged; introduces an evident "
      ^ "syntax, type, or behavioral defect; or cannot plausibly replace the indicated lines.";
    false_criteria =
      "The payload is a concrete, mechanically plausible change that addresses the stated defect in the shown code. "
      ^ "It need not be the only or most elegant repair, and incomplete repository context alone is not a defect.";
  }

let suggestion_plausibility : Decision_client.noul_question =
  {
    instructions =
      "Is `suggested_fix` a concrete, mechanically plausible actionable replacement for the validated finding at "
      ^ "its indicated location, given the exact reviewed-file diff? Judge only the fix payload.";
    true_criteria =
      "The payload can plausibly replace the indicated code and address the stated defect without an evident syntax, "
      ^ "type, control-flow, ordering, or behavioral error. It need not be the only or most elegant repair.";
    false_criteria =
      "The payload is a no-op, prose, placeholder code, anchored to incompatible lines, duplicates existing behavior, "
      ^ "leaves the defect unchanged, or introduces an evident defect. Missing repository context alone is "
      ^ "uncertainty, not proof of invalidity.";
  }

let build_claim : Decision_client.noul_question =
  {
    instructions =
      "Do `reviewed_file_context` or `completed_commit_checks` directly disprove the finding's claimed "
      ^ "deterministic compile or build failure at this exact commit? Answer only about explicit syntax, binding, "
      ^ "name-resolution, arity, type, or linking claims.";
    true_criteria =
      "Either the shown source directly establishes the disputed construct is valid, or a successful completed "
      ^ "check clearly compiled the affected language/component at this exact commit and no clearly relevant build "
      ^ "check failed. Unrelated failed checks do not outweigh a relevant successful build.";
    false_criteria =
      "The claimed build defect is real, a clearly relevant build check failed, neither source nor checks directly "
      ^ "disprove the exact claim, the finding concerns runtime behavior, or evidence is uncertain. Uncertainty is "
      ^ "false.";
  }
