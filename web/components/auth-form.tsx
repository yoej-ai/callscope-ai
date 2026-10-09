"use client";

import Link from "next/link";
import { useFormStatus } from "react-dom";

type AuthFormProps = {
  mode: "sign-in" | "sign-up";
  message?: string;
  action: (formData: FormData) => Promise<void>;
};

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
      className="button primary"
      disabled={pending}
      type="submit"
    >
      {label}
    </button>
  );
}

export function AuthForm({ mode, message, action }: AuthFormProps) {
  const isSignIn = mode === "sign-in";

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

        {message ? (
          <p className="form-message" role="status">
            {message}
          </p>
        ) : null}

        <form action={action} className="auth-form">
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
          <Link href={isSignIn ? "/sign-up" : "/sign-in"}>
            {isSignIn ? "Create an account" : "Sign in"}
          </Link>
        </p>
      </section>
    </main>
  );
}
