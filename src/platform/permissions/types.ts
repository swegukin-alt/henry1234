import type { PermissionName, PermissionState, PlatformService } from "../types";

export type PermissionService = PlatformService & {
  check: (name: PermissionName) => Promise<PermissionState>;
  request: (name: PermissionName) => Promise<PermissionState>;
  /** iOS only: send the user to the app's Settings page after a hard denial. */
  canOpenSettings: () => boolean;
  openSettings: () => Promise<void>;
};
