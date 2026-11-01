import { createRootRoute, Outlet } from "@tanstack/react-router";

// API-only service: routes under /api use server handlers, no pages render.
export const Route = createRootRoute({ component: Outlet });
