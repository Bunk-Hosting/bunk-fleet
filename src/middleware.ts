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

async function verifyJwt(token: string): Promise<JwtPayload | null> {
  try {
    const secret = process.env.JWT_SECRET;
    if (!secret) return null;
    const { payload } = await jwtVerify(token, new TextEncoder().encode(secret));
    return payload as unknown as JwtPayload;
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
