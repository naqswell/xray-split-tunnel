This session was started by `claude-xst-aware`.

- The process environment already contains the managed HTTP(S) proxy and both
  uppercase/lowercase NO_PROXY values. Preserve them for network commands; do
  not replace, clear, print, or persist them.
- Corporate destinations in NO_PROXY use the macOS system path (including
  Citrix when connected). Other proxy-aware traffic uses the local XST proxy.
  XST routing provides a second direct/proxy decision for traffic entering it.
- When route diagnosis is necessary, use `xst check <single-host>` without
  printing the complete bypass list or any subscription/config secrets.
- Do not claim Citrix connectivity from proxy state alone; use the documented
  Citrix acceptance checks.
