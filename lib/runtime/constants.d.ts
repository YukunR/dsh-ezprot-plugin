/** Plugin package root (one level above src/). */
export declare const packageDir: string;
export declare const R_VERSION = "4.4.0";
export declare const BIOC_VERSION = "3.20";
export declare const DEFAULT_MIRRORS: {
    cran: string;
    bioc: string;
    rBase: string;
    fallbackCran: string;
    fallbackBioc: string;
    fallbackRBase: string;
};
export declare const LINUX_BINARY_CRAN = "https://packagemanager.posit.co/cran/__linux__/jammy/2024-11-15";
/** Fallback image when no dockerImage is configured or persisted. */
export declare const DEFAULT_DOCKER_IMAGE = "ezprot:latest";
/** The package-install script shipped inside the package. */
export declare const installScriptPath: () => string;
/** The runtime probe script shipped inside the package. */
export declare const checkScriptPath: () => string;
