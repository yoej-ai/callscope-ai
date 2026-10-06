"use server";

import { headers } from "next/headers";
import { redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";

function messagePath(path: string, message: string) {
  return `${path}?message=${encodeURIComponent(message)}`;
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
  const values = credentials(formData);
  if (!values) {
    redirect(messagePath("/sign-in", "Enter a valid email and password."));
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword(values);

  if (error) {
    redirect(messagePath("/sign-in", "Unable to sign in with those credentials."));
  }

  redirect("/dashboard");
}

export async function signUp(formData: FormData) {
  const values = credentials(formData);
  if (!values) {
    redirect(
      messagePath("/sign-up", "Use a valid email and at least 8 characters."),
    );
  }

  const headerStore = await headers();
  const origin = headerStore.get("origin") ?? "http://localhost:3000";
  const supabase = await createClient();
  const { error } = await supabase.auth.signUp({
    ...values,
    options: { emailRedirectTo: `${origin}/auth/callback` },
  });

  if (error) {
    redirect(messagePath("/sign-up", "Unable to create the account."));
  }

  redirect(
    messagePath(
      "/sign-in",
      "Account created. Check your email if confirmation is required.",
    ),
  );
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/");
}
