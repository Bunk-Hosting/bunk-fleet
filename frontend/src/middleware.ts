import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

// Auth is an HttpOnly `bunk_session` cookie set by the control plane. This
// middleware only checks its PRESENCE for UX redirects (avoiding a flash of
// protected UI); the real authorization boundary is the API, which validates the
// session on every request. Middleware runs server-side, so it can read the
// HttpOnly cookie even though client JS cannot.
export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const isLoggedIn = Boolean(request.cookies.get("bunk_session")?.value);

  // Send logged-in users away from the auth-only pages.
  const authOnlyPaths = ["/login", "/register", "/forgot-password"];
  if (authOnlyPaths.includes(pathname) && isLoggedIn) {
    return NextResponse.redirect(new URL("/dashboard", request.url));
  }

  // Protect dashboard routes.
  if (pathname.startsWith("/dashboard")) {
    if (!isLoggedIn) {
      const loginUrl = new URL("/login", request.url);
      loginUrl.searchParams.set("next", pathname);
      return NextResponse.redirect(loginUrl);
    }
    // /dashboard/beheer/* (admin panel) is authorized server-side: every
    // /api/v1/admin/* call requires the :admin role (403 otherwise) and the
    // pages wrap in <AdminGuard>. An opaque token can't carry the role, so we
    // don't gate it here.
  }

  return NextResponse.next();
}

export const config = {
  matcher: ["/dashboard/:path*", "/login", "/register", "/forgot-password"],
};
