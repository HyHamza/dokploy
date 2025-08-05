import { pgEnum } from "drizzle-orm/pg-core";

export const serviceType = pgEnum("serviceType", [
	"application",
	"postgres",
	"mysql",
	"mariadb",
	"mongo",
	"redis",
	"compose",
]);
