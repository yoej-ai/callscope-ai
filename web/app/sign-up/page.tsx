import { signUp } from "@/app/auth/actions";
import { AuthForm } from "@/components/auth-form";

type SignUpPageProps = {
  searchParams: Promise<{ message?: string }>;
};

export default async function SignUpPage({ searchParams }: SignUpPageProps) {
  const { message } = await searchParams;
  return <AuthForm action={signUp} message={message} mode="sign-up" />;
}
