"use server";

import { redirect } from "next/navigation";

import {
  getAuthCallbackUrl,
  getGoogleOAuthOptions,
} from "@/lib/app-url";
import { normalizeSafeAuthRedirectPath } from "@/lib/auth/redirect-target.mjs";
import { createClient } from "@/lib/supabase/server";

function formNextPath(formData: FormData) {
  const requestedNext = formData.get("next");
  return normalizeSafeAuthRedirectPath(
    typeof requestedNext === "string" ? requestedNext : null,
  );
}

function messagePath(path: string, message: string, next?: string) {
  const parameters = new URLSearchParams({ message });
  if (next) parameters.set("next", next);
  return `${path}?${parameters.toString()}`;
}

function credentials(formData: FormData) {
  const email = formData.get("email");
  const password = formData.get("password");

  if (typeof email !== "string" || typeof password !== "string") {
    return null;
  }

  const normalizedEmail = email.trim().toLowerCase();
  if (!normalizedEmail || password.length < 8) {
    return null;
  }

  return { email: normalizedEmail, password };
}

export async function signIn(formData: FormData) {
  const next = formNextPath(formData);
  const values = credentials(formData);
  if (!values) {
    redirect(
      messagePath("/sign-in", "Enter a valid email and password.", next),
    );
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword(values);

  if (error) {
    redirect(
      messagePath(
        "/sign-in",
        "Unable to sign in with those credentials.",
        next,
      ),
    );
  }

  redirect(next);
}

export async function signUp(formData: FormData) {
  const next = formNextPath(formData);
  const values = credentials(formData);
  if (!values) {
    redirect(
      messagePath(
        "/sign-up",
        "Use a valid email and at least 8 characters.",
        next,
      ),
    );
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signUp({
    ...values,
    options: { emailRedirectTo: getAuthCallbackUrl(next) },
  });

  if (error) {
    redirect(messagePath("/sign-up", "Unable to create the account.", next));
  }

  redirect(
    messagePath(
      "/sign-in",
      "Account created. Check your email if confirmation is required.",
      next,
    ),
  );
}

export async function signInWithGoogle(formData: FormData) {
  const next = formNextPath(formData);
  const supabase = await createClient();
  const { data, error } = await supabase.auth.signInWithOAuth(
    getGoogleOAuthOptions(next),
  );

  if (error || !data.url) {
    redirect(
      messagePath(
        "/sign-in",
        "Google sign-in could not be started. Please try again.",
        next,
      ),
    );
  }

  redirect(data.url);
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/");
}
