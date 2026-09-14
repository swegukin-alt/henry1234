import { pickImpl } from "../runtime";
import type { PermissionName, PermissionState } from "../types";
import { webPermissions } from "./web";
import type { PermissionService } from "./types";

export type { PermissionService } from "./types";

let resolved: Promise<PermissionService> | null = null;

export function permissionService(): Promise<PermissionService> {
  resolved ??= pickImpl(webPermissions, async () => (await import("./native")).nativePermissions);
  return resolved;
}

export const checkPermission = async (name: PermissionName): Promise<PermissionState> =>
  (await permissionService()).check(name);

export const requestPermission = async (name: PermissionName): Promise<PermissionState> =>
  (await permissionService()).request(name);

export const openAppSettings = async (): Promise<boolean> => {
  const svc = await permissionService();
  if (!svc.canOpenSettings()) return false;
  await svc.openSettings();
  return true;
};
