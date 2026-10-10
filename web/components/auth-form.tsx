"use client";

import Link from "next/link";
import { useFormStatus } from "react-dom";

type AuthFormProps = {
  mode: "sign-in" | "sign-up";
  message?: string;
  nextPath: string;
  action: (formData: FormData) => Promise<void>;
  googleAction: (formData: FormData) => Promise<void>;
};

function GoogleMark() {
  return (
    <svg
      aria-hidden="true"
      className="google-mark"
      viewBox="0 0 24 24"
    >
      <path
        d="M21.6 12.23c0-.71-.06-1.4-.18-2.07H12v3.92h5.38a4.6 4.6 0 0 1-2 3.02v2.54h3.24c1.9-1.75 2.98-4.33 2.98-7.41Z"
        fill="#4285F4"
      />
      <path
        d="M12 22c2.7 0 4.98-.9 6.64-2.43l-3.24-2.54c-.9.6-2.05.96-3.4.96-2.61 0-4.82-1.76-5.61-4.13H3.04v2.62A10.03 10.03 0 0 0 12 22Z"
        fill="#34A853"
      />
      <path
        d="M6.39 13.86A6.03 6.03 0 0 1 6.07 12c0-.65.11-1.28.32-1.86V7.52H3.04A10.02 10.02 0 0 0 2 12c0 1.61.38 3.14 1.04 4.48l3.35-2.62Z"
        fill="#FBBC05"
      />
      <path
        d="M12 6.01c1.47 0 2.78.5 3.82 1.49l2.88-2.88A9.65 9.65 0 0 0 12 2a10.03 10.03 0 0 0-8.96 5.52l3.35 2.62C7.18 7.77 9.39 6.01 12 6.01Z"
        fill="#EA4335"
      />
    </svg>
  );
}

function GoogleSubmitButton() {
  const { pending } = useFormStatus();

  return (
    <button
      aria-busy={pending}
      className="button google-auth-button"
      disabled={pending}
      type="submit"
    >
      <GoogleMark />
      {pending ? "Connecting to Google..." : "Continue with Google"}
    </button>
  );
}

function AuthSubmitButton({ isSignIn }: { isSignIn: boolean }) {
  const { pending } = useFormStatus();

  const label = isSignIn
    ? pending
      ? "Signing in..."
      : "Sign in"
    : pending
      ? "Creating account..."
      : "Create account";

  return (
    <button
      aria-busy={pending}
      className="button secondary"
      disabled={pending}
      type="submit"
    >
      {label}
    </button>
  );
}

export function AuthForm({
  mode,
  message,
  nextPath,
  action,
  googleAction,
}: AuthFormProps) {
  const isSignIn = mode === "sign-in";
  const switchPath = isSignIn ? "/sign-up" : "/sign-in";
  const switchHref = `${switchPath}?next=${encodeURIComponent(nextPath)}`;

  return (
    <main className="auth-shell">
      <section className="auth-card" aria-labelledby="auth-title">
        <Link className="brand" href="/">
          CallScope AI
        </Link>
        <p className="eyebrow">Secure workspace access</p>
        <h1 id="auth-title">{isSignIn ? "Welcome back" : "Create your account"}</h1>
        <p className="muted">
          {isSignIn
            ? "Sign in to review your team’s call intelligence."
            : "Start building a shared source of truth for every customer call."}
        </p>

        <div className="auth-message-slot" aria-live="polite">
          {message ? (
            <p className="form-message" role="status">
              {message}
            </p>
          ) : null}
        </div>

        <form action={googleAction} className="oauth-form">
          <input name="next" type="hidden" value={nextPath} />
          <GoogleSubmitButton />
        </form>

        <div className="auth-divider" aria-hidden="true">
          <span>or continue with email</span>
        </div>

        <form action={action} className="auth-form">
          <input name="next" type="hidden" value={nextPath} />
          <label htmlFor="email">Email address</label>
          <input
            autoComplete="email"
            id="email"
            name="email"
            placeholder="you@company.com"
            required
            type="email"
          />
          <label htmlFor="password">Password</label>
          <input
            autoComplete={isSignIn ? "current-password" : "new-password"}
            id="password"
            minLength={8}
            name="password"
            required
            type="password"
          />
          <AuthSubmitButton isSignIn={isSignIn} />
        </form>

        <p className="auth-switch">
          {isSignIn ? "New to CallScope AI?" : "Already have an account?"}{" "}
          <Link href={switchHref}>
            {isSignIn ? "Create an account" : "Sign in"}
          </Link>
        </p>
      </section>
    </main>
  );
}
