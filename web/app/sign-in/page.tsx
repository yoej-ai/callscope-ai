import { signIn, signInWithGoogle } from "@/app/auth/actions";
import { AuthForm } from "@/components/auth-form";
import { normalizeSafeAuthRedirectPath } from "@/lib/auth/redirect-target.mjs";

type SignInPageProps = {
  searchParams: Promise<{
    message?: string | string[];
    next?: string | string[];
  }>;
};

export default async function SignInPage({ searchParams }: SignInPageProps) {
  const { message, next } = await searchParams;
  return (
    <AuthForm
      action={signIn}
      googleAction={signInWithGoogle}
      message={typeof message === "string" ? message : undefined}
      mode="sign-in"
      nextPath={normalizeSafeAuthRedirectPath(
        typeof next === "string" ? next : null,
      )}
    />
  );
}
