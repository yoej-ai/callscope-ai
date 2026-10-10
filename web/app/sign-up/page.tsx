import { signInWithGoogle, signUp } from "@/app/auth/actions";
import { AuthForm } from "@/components/auth-form";
import { normalizeSafeAuthRedirectPath } from "@/lib/auth/redirect-target.mjs";

type SignUpPageProps = {
  searchParams: Promise<{
    message?: string | string[];
    next?: string | string[];
  }>;
};

export default async function SignUpPage({ searchParams }: SignUpPageProps) {
  const { message, next } = await searchParams;
  return (
    <AuthForm
      action={signUp}
      googleAction={signInWithGoogle}
      message={typeof message === "string" ? message : undefined}
      mode="sign-up"
      nextPath={normalizeSafeAuthRedirectPath(
        typeof next === "string" ? next : null,
      )}
    />
  );
}
