{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    // GitHub Pages cannot provide the COOP/COEP response headers required by
    // Skwasm workers. Use Flutter's supported single-threaded fallback without
    // warning users about a hosting capability this deployment cannot enable.
    suppressMultithreadingWarning: true,
  },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
});
