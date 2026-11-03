// Panel defaults. The Docker image rewrites this file at startup from its environment
// (see web/docker/40-rsdw-panel.sh); edit it by hand when hosting the panel yourself.
//   apiUrl:     API address pre-filled in the panel, e.g. "https://api.example.com"
//   sameOrigin: true when the API is reachable at this page's own address under /api/
window.RSDW_CONFIG = {
  apiUrl: "",
  sameOrigin: false,
};
