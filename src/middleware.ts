import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

// bunk-fleet issues opaque bearer session tokens (not JWTs), so this middleware
// can only check the token's PRESENCE for UX redirects. The real authorization
// boundary is the API, which validates every bearer token. The token is mirrored
// into an `access_token` cookie (alongside localStorage) purely so this
// server-side gate runs without a flash of protected UI.
export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const isLoggedIn = Boolean(request.cookies.get("access_token")?.value);

  // Send logged-in users away from the auth-only pages.
  const authOnlyPaths = ["/login", "/register", "/forgot-password", "/reset-password"];
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

    // Admin (beheer) is served by the bunk-fleet control-plane admin UI, not this
    // app. A role can't be derived from an opaque token, so deny here (fail
    // securely / least privilege) rather than leak a non-functional admin panel.
    if (pathname.startsWith("/dashboard/beheer")) {
      return NextResponse.redirect(new URL("/dashboard", request.url));
    }
  }

  return NextResponse.next();
}

export const config = {
  matcher: ["/dashboard/:path*", "/login", "/register", "/forgot-password", "/reset-password", "/verify-email"],
};
