import { PageHeader, PageHeaderHeading } from "@/components/page-header";
import { DlpWorkloadCoverageCard } from "@/components/overview/dlp-workload-coverage";
import { SensitivityLabelProtectionSankey } from "@/components/overview/sensitivity-label-protection-sankey";
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { columns } from "@/components/test-table/columns";
import { DataTable } from "@/components/test-table/data-table";
import { reportData } from "@/config/report-data";
import { Database } from "lucide-react";

export default function Data() {
    const hasSensitivityLabelProtection = Object.prototype.hasOwnProperty.call(
        reportData.TenantInfo ?? {},
        "SensitivityLabelProtection",
    );
    const hasDlpWorkloadCoverage = Object.prototype.hasOwnProperty.call(
        reportData.TenantInfo ?? {},
        "DlpWorkloadCoverage",
    );

    return (
        <>
            <PageHeader>
                <PageHeaderHeading>Data</PageHeaderHeading>
            </PageHeader>
            {(hasSensitivityLabelProtection || hasDlpWorkloadCoverage) && (
                <Card className="mb-6">
                    <CardContent className="px-4 pb-3 pt-1">
                        <Accordion type="single" collapsible defaultValue="data-insights" className="w-full">
                            <AccordionItem value="data-insights" className="border-b-0">
                                <AccordionTrigger className="py-3 hover:no-underline">
                                    <div className="flex flex-1 items-center gap-3 text-left">
                                        <div className="flex size-10 shrink-0 items-center justify-center rounded-md bg-muted text-foreground">
                                            <Database className="size-5" />
                                        </div>
                                        <div className="flex flex-col gap-0.5">
                                            <span className="text-lg font-semibold leading-none">Data insights</span>
                                            <span className="text-sm font-normal text-muted-foreground">
                                                An overview of your data classification, protection, and governance posture.
                                            </span>
                                        </div>
                                    </div>
                                </AccordionTrigger>
                                <AccordionContent className="pb-2">
                                    <div className="grid grid-cols-1 items-stretch gap-6 lg:grid-cols-2">
                                        {hasSensitivityLabelProtection && <SensitivityLabelProtectionSankey />}
                                        {hasDlpWorkloadCoverage && (
                                            <DlpWorkloadCoverageCard data={reportData.TenantInfo?.DlpWorkloadCoverage} />
                                        )}
                                    </div>
                                </AccordionContent>
                            </AccordionItem>
                        </Accordion>
                    </CardContent>
                </Card>
            )}
            <Card>
                <CardHeader>
                    <CardTitle className="mb-3">Assessment results</CardTitle>
                    <CardDescription>
                        The results presented below are based on the security principles detailed in the{" "}
                        <a
                            href="https://learn.microsoft.com/en-us/purview/configure-security"
                            target="_blank"
                            rel="noopener noreferrer"
                            className="text-primary font-medium underline underline-offset-4 hover:underline"
                        >
                            Configuring Microsoft Purview for increased security
                        </a>
                        {" "}guide.
                    </CardDescription>
                </CardHeader>
                <CardContent className="gap-4 px-4 pb-4 pt-1">
                    <DataTable columns={columns} data={reportData.Tests} pillar="Data" />
                </CardContent>
            </Card>
        </>
    )
}
