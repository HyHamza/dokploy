import { DashboardLayout } from "@/components/layouts/dashboard-layout";
import { Button } from "@/components/ui/button";
import {
	Card,
	CardContent,
	CardDescription,
	CardFooter,
	CardHeader,
	CardTitle,
} from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { api } from "@/utils/api";
import { getLocale, serverSideTranslations } from "@/utils/i18n";
import { validateRequest } from "@dokploy/server";
import { createServerSideHelpers } from "@trpc/react-query/server";
import type { GetServerSidePropsContext } from "next";
import type { ReactElement } from "react";
import { toast } from "sonner";
import superjson from "superjson";
import { appRouter } from "@/server/api/root";
import { useTranslation } from "next-i18next";

const AuthenticationPage = () => {
	const { t } = useTranslation("settings");
	const { data, refetch } = api.settings.getPublicRegistrationStatus.useQuery();
	const { mutateAsync, isLoading } =
		api.settings.updatePublicRegistrationStatus.useMutation();

	const handleToggle = async (enabled: boolean) => {
		await mutateAsync({ enabled })
			.then(() => {
				toast.success("Settings updated successfully");
				refetch();
			})
			.catch(() => {
				toast.error("Failed to update settings");
			});
	};

	return (
		<Card>
			<CardHeader>
				<CardTitle>Public Registration</CardTitle>
				<CardDescription>
					Allow users to register themselves on the login page.
				</CardDescription>
			</CardHeader>
			<CardContent>
				<div className="flex items-center space-x-2">
					<Switch
						id="public-registration"
						checked={data?.isPublicRegistrationEnabled}
						onCheckedChange={handleToggle}
						disabled={isLoading}
					/>
					<Label htmlFor="public-registration">
						{data?.isPublicRegistrationEnabled ? "Enabled" : "Disabled"}
					</Label>
				</div>
			</CardContent>
		</Card>
	);
};

const Page = () => {
	return (
		<div className="w-full">
			<div className="h-full rounded-xl max-w-5xl mx-auto flex flex-col gap-4">
				<AuthenticationPage />
			</div>
		</div>
	);
};

export default Page;

Page.getLayout = (page: ReactElement) => {
	return <DashboardLayout metaName="Authentication">{page}</DashboardLayout>;
};

export async function getServerSideProps(
	ctx: GetServerSidePropsContext<{ serviceId: string }>,
) {
	const { req, res } = ctx;
	const locale = getLocale(req.cookies);
	const { user, session } = await validateRequest(req);

	const helpers = createServerSideHelpers({
		router: appRouter,
		ctx: {
			req: req as any,
			res: res as any,
			db: null as any,
			session: session as any,
			user: user as any,
		},
		transformer: superjson,
	});

	await helpers.settings.getPublicRegistrationStatus.prefetch();

	if (!user || user.role !== "owner") {
		return {
			redirect: {
				permanent: true,
				destination: "/",
			},
		};
	}

	return {
		props: {
			trpcState: helpers.dehydrate(),
			...(await serverSideTranslations(locale, ["settings"])),
		},
	};
}
