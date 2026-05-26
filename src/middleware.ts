import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import { jwtVerify } from "jose";

interface JwtPayload {
  user_id: number;
  email: string;
  name: string;
  role: "user" | "admin";
  exp: number;
}

// Runtime-typeguard zodat we niet blind `as unknown as JwtPayload` casten.
// jose verifieert de handtekening, maar niet de claim-shape: een gecorrumpeerd
// of geforget token met onverwachte velden zou anders silently accepted worden.
function isJwtPayload(value: unknown): value is JwtPayload {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.user_id === "number" &&
    typeof v.email === "string" &&
    typeof v.name === "string" &&
    (v.role === "user" || v.role === "admin") &&
    typeof v.exp === "number"
  );
}

async function verifyJwt(token: string): Promise<JwtPayload | null> {
  try {
    const secret = process.env.JWT_SECRET;
    if (!secret) return null;
    const { payload } = await jwtVerify(token, new TextEncoder().encode(secret));
    return isJwtPayload(payload) ? payload : null;
  } catch {
    return null;
  }
}

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const accessToken = request.cookies.get("access_token")?.value;

  const payload = accessToken ? await verifyJwt(accessToken) : null;
  const isLoggedIn = payload !== null;

  // Redirect logged-in users away from auth pages
  const authOnlyPaths = ["/login", "/register", "/forgot-password", "/reset-password"];
  if (authOnlyPaths.includes(pathname) && isLoggedIn) {
    return NextResponse.redirect(new URL("/dashboard", request.url));
  }

  // Protect dashboard routes
  if (pathname.startsWith("/dashboard")) {
    if (!isLoggedIn) {
      const loginUrl = new URL("/login", request.url);
      loginUrl.searchParams.set("next", pathname);
      return NextResponse.redirect(loginUrl);
    }

    // Protect admin routes
    if (pathname.startsWith("/dashboard/beheer") && payload?.role !== "admin") {
      return NextResponse.redirect(new URL("/dashboard", request.url));
    }
  }

  return NextResponse.next();
}

export const config = {
  matcher: ["/dashboard/:path*", "/login", "/register", "/forgot-password", "/reset-password", "/verify-email"],
};
