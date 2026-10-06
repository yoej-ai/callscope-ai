import { signIn } from "@/app/auth/actions";
import { AuthForm } from "@/components/auth-form";

type SignInPageProps = {
  searchParams: Promise<{ message?: string }>;
};

export default async function SignInPage({ searchParams }: SignInPageProps) {
  const { message } = await searchParams;
  return <AuthForm action={signIn} message={message} mode="sign-in" />;
}
