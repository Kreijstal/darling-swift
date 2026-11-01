// Bridging header for coremedia_network.swift: a queue for NWPathMonitor.start(queue:), whose
// type comes from the Network overlay's shim since the test does not import the Dispatch overlay.
@import _DarlingNetworkShims;

OS_dispatch_queue *dispatch_queue_create(const char *label, void *attr);
