/**
 * Simple Accounting Books - Cross-company relationship protection.
 *
 * Step 7B.
 *
 * The global product contract requires Company to agree across headers,
 * periods, GL accounts, party profiles, bank accounts, dimensions, accounting
 * events and related financial documents even when records arrive through API
 * or import.
 *
 * Existing foundation Validation Rules already protect several configuration
 * relationships (for example Party Profile AR/AP/Payment Term, Department
 * parent and GL parent). This service focuses on transaction relationships that
 * need reusable server-side Apex enforcement.
 */
public without sharing class SABCrossCompanyGuardService {

    private static final String ERROR_PREFIX =
        'Cross-company relationship is not allowed. ';

    public static void validateJournals(
        List<Journal_Entry__c> records
    ) {
        Set<Id> periodIds = new Set<Id>();
        Set<Id> eventIds = new Set<Id>();
        Set<Id> journalIds = new Set<Id>();

        for (Journal_Entry__c recordValue : records) {
            if (recordValue.Accounting_Period__c != null) {
                periodIds.add(recordValue.Accounting_Period__c);
            }
            if (recordValue.Accounting_Event__c != null) {
                eventIds.add(recordValue.Accounting_Event__c);
            }
            if (recordValue.Reversal_Of__c != null) {
                journalIds.add(recordValue.Reversal_Of__c);
            }
            if (recordValue.Reversal_Journal__c != null) {
                journalIds.add(recordValue.Reversal_Journal__c);
            }
        }

        Map<Id, Accounting_Period__c> periods =
            periodIds.isEmpty()
                ? new Map<Id, Accounting_Period__c>()
                : new Map<Id, Accounting_Period__c>([
                    SELECT Id, Company__c
                    FROM Accounting_Period__c
                    WHERE Id IN :periodIds
                ]);

        Map<Id, Accounting_Event__c> events =
            eventIds.isEmpty()
                ? new Map<Id, Accounting_Event__c>()
                : new Map<Id, Accounting_Event__c>([
                    SELECT Id, Company__c
                    FROM Accounting_Event__c
                    WHERE Id IN :eventIds
                ]);

        Map<Id, Journal_Entry__c> relatedJournals =
            journalIds.isEmpty()
                ? new Map<Id, Journal_Entry__c>()
                : new Map<Id, Journal_Entry__c>([
                    SELECT Id, Company__c
                    FROM Journal_Entry__c
                    WHERE Id IN :journalIds
                ]);

        for (Journal_Entry__c recordValue : records) {
            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Accounting_Period__c,
                relatedCompanyId(periods, recordValue.Accounting_Period__c),
                'Accounting Period'
            );

            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Accounting_Event__c,
                relatedCompanyId(events, recordValue.Accounting_Event__c),
                'Accounting Event'
            );

            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Reversal_Of__c,
                relatedCompanyId(relatedJournals, recordValue.Reversal_Of__c),
                'Reversal Of Journal'
            );

            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Reversal_Journal__c,
                relatedCompanyId(relatedJournals, recordValue.Reversal_Journal__c),
                'Reversal Journal'
            );
        }
    }

    public static void validateJournalLines(
        List<Journal_Entry_Line__c> records
    ) {
        Set<Id> journalIds = new Set<Id>();
        Set<Id> accountIds = new Set<Id>();
        Set<Id> departmentIds = new Set<Id>();
        Set<Id> costCenterIds = new Set<Id>();
        Set<Id> projectIds = new Set<Id>();

        for (Journal_Entry_Line__c recordValue : records) {
            if (recordValue.Journal_Entry__c != null) {
                journalIds.add(recordValue.Journal_Entry__c);
            }
            if (recordValue.GL_Account__c != null) {
                accountIds.add(recordValue.GL_Account__c);
            }
            if (recordValue.Department__c != null) {
                departmentIds.add(recordValue.Department__c);
            }
            if (recordValue.Cost_Center__c != null) {
                costCenterIds.add(recordValue.Cost_Center__c);
            }
            if (recordValue.Project__c != null) {
                projectIds.add(recordValue.Project__c);
            }
        }

        Map<Id, Journal_Entry__c> journals =
            journalIds.isEmpty()
                ? new Map<Id, Journal_Entry__c>()
                : new Map<Id, Journal_Entry__c>([
                    SELECT Id, Company__c
                    FROM Journal_Entry__c
                    WHERE Id IN :journalIds
                ]);

        Map<Id, GL_Account__c> accounts =
            accountIds.isEmpty()
                ? new Map<Id, GL_Account__c>()
                : new Map<Id, GL_Account__c>([
                    SELECT Id, Company__c
                    FROM GL_Account__c
                    WHERE Id IN :accountIds
                ]);

        Map<Id, Department__c> departments =
            departmentIds.isEmpty()
                ? new Map<Id, Department__c>()
                : new Map<Id, Department__c>([
                    SELECT Id, Company__c
                    FROM Department__c
                    WHERE Id IN :departmentIds
                ]);

        Map<Id, Cost_Center__c> costCenters =
            costCenterIds.isEmpty()
                ? new Map<Id, Cost_Center__c>()
                : new Map<Id, Cost_Center__c>([
                    SELECT Id, Company__c
                    FROM Cost_Center__c
                    WHERE Id IN :costCenterIds
                ]);

        Map<Id, Project__c> projects =
            projectIds.isEmpty()
                ? new Map<Id, Project__c>()
                : new Map<Id, Project__c>([
                    SELECT Id, Company__c
                    FROM Project__c
                    WHERE Id IN :projectIds
                ]);

        for (Journal_Entry_Line__c recordValue : records) {
            Journal_Entry__c journal =
                journals.get(recordValue.Journal_Entry__c);

            if (journal == null) {
                continue;
            }

            Id companyId = journal.Company__c;

            assertSameCompany(
                recordValue,
                companyId,
                recordValue.GL_Account__c,
                relatedCompanyId(accounts, recordValue.GL_Account__c),
                'GL Account'
            );

            assertSameCompany(
                recordValue,
                companyId,
                recordValue.Department__c,
                relatedCompanyId(departments, recordValue.Department__c),
                'Department'
            );

            assertSameCompany(
                recordValue,
                companyId,
                recordValue.Cost_Center__c,
                relatedCompanyId(costCenters, recordValue.Cost_Center__c),
                'Cost Center'
            );

            assertSameCompany(
                recordValue,
                companyId,
                recordValue.Project__c,
                relatedCompanyId(projects, recordValue.Project__c),
                'Project'
            );
        }
    }

    public static void validateBankAccounts(
        List<Bank_Account__c> records
    ) {
        Set<Id> accountIds = new Set<Id>();

        for (Bank_Account__c recordValue : records) {
            if (recordValue.GL_Account__c != null) {
                accountIds.add(recordValue.GL_Account__c);
            }
        }

        Map<Id, GL_Account__c> accounts =
            accountIds.isEmpty()
                ? new Map<Id, GL_Account__c>()
                : new Map<Id, GL_Account__c>([
                    SELECT Id, Company__c
                    FROM GL_Account__c
                    WHERE Id IN :accountIds
                ]);

        for (Bank_Account__c recordValue : records) {
            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.GL_Account__c,
                relatedCompanyId(accounts, recordValue.GL_Account__c),
                'Bank GL Account'
            );
        }
    }

    public static void validateInvoices(
        List<Invoice__c> records
    ) {
        Set<Id> profileIds = new Set<Id>();
        Set<Id> eventIds = new Set<Id>();
        Set<Id> invoiceIds = new Set<Id>();

        for (Invoice__c recordValue : records) {
            if (recordValue.Party_Profile__c != null) {
                profileIds.add(recordValue.Party_Profile__c);
            }
            if (recordValue.Accounting_Event__c != null) {
                eventIds.add(recordValue.Accounting_Event__c);
            }
            if (recordValue.Original_Invoice__c != null) {
                invoiceIds.add(recordValue.Original_Invoice__c);
            }
        }

        Map<Id, Party_Accounting_Profile__c> profiles =
            profileIds.isEmpty()
                ? new Map<Id, Party_Accounting_Profile__c>()
                : new Map<Id, Party_Accounting_Profile__c>([
                    SELECT Id, Company__c
                    FROM Party_Accounting_Profile__c
                    WHERE Id IN :profileIds
                ]);

        Map<Id, Accounting_Event__c> events =
            eventIds.isEmpty()
                ? new Map<Id, Accounting_Event__c>()
                : new Map<Id, Accounting_Event__c>([
                    SELECT Id, Company__c
                    FROM Accounting_Event__c
                    WHERE Id IN :eventIds
                ]);

        Map<Id, Invoice__c> originals =
            invoiceIds.isEmpty()
                ? new Map<Id, Invoice__c>()
                : new Map<Id, Invoice__c>([
                    SELECT Id, Company__c
                    FROM Invoice__c
                    WHERE Id IN :invoiceIds
                ]);

        for (Invoice__c recordValue : records) {
            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Party_Profile__c,
                relatedCompanyId(profiles, recordValue.Party_Profile__c),
                'Party Accounting Profile'
            );

            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Accounting_Event__c,
                relatedCompanyId(events, recordValue.Accounting_Event__c),
                'Accounting Event'
            );

            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Original_Invoice__c,
                relatedCompanyId(originals, recordValue.Original_Invoice__c),
                'Original Invoice'
            );
        }
    }

    public static void validateSupplierBills(
        List<Supplier_Bill__c> records
    ) {
        Set<Id> profileIds = new Set<Id>();
        Set<Id> eventIds = new Set<Id>();

        for (Supplier_Bill__c recordValue : records) {
            if (recordValue.Supplier_Profile__c != null) {
                profileIds.add(recordValue.Supplier_Profile__c);
            }
            if (recordValue.Accounting_Event__c != null) {
                eventIds.add(recordValue.Accounting_Event__c);
            }
        }

        Map<Id, Party_Accounting_Profile__c> profiles =
            profileIds.isEmpty()
                ? new Map<Id, Party_Accounting_Profile__c>()
                : new Map<Id, Party_Accounting_Profile__c>([
                    SELECT Id, Company__c
                    FROM Party_Accounting_Profile__c
                    WHERE Id IN :profileIds
                ]);

        Map<Id, Accounting_Event__c> events =
            eventIds.isEmpty()
                ? new Map<Id, Accounting_Event__c>()
                : new Map<Id, Accounting_Event__c>([
                    SELECT Id, Company__c
                    FROM Accounting_Event__c
                    WHERE Id IN :eventIds
                ]);

        for (Supplier_Bill__c recordValue : records) {
            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Supplier_Profile__c,
                relatedCompanyId(profiles, recordValue.Supplier_Profile__c),
                'Supplier Accounting Profile'
            );

            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Accounting_Event__c,
                relatedCompanyId(events, recordValue.Accounting_Event__c),
                'Accounting Event'
            );
        }
    }

    public static void validatePayments(
        List<Accounting_Payment__c> records
    ) {
        Set<Id> bankIds = new Set<Id>();
        Set<Id> profileIds = new Set<Id>();
        Set<Id> eventIds = new Set<Id>();

        for (Accounting_Payment__c recordValue : records) {
            if (recordValue.Bank_Account__c != null) {
                bankIds.add(recordValue.Bank_Account__c);
            }
            if (recordValue.Party_Profile__c != null) {
                profileIds.add(recordValue.Party_Profile__c);
            }
            if (recordValue.Accounting_Event__c != null) {
                eventIds.add(recordValue.Accounting_Event__c);
            }
        }

        Map<Id, Bank_Account__c> banks =
            bankIds.isEmpty()
                ? new Map<Id, Bank_Account__c>()
                : new Map<Id, Bank_Account__c>([
                    SELECT Id, Company__c
                    FROM Bank_Account__c
                    WHERE Id IN :bankIds
                ]);

        Map<Id, Party_Accounting_Profile__c> profiles =
            profileIds.isEmpty()
                ? new Map<Id, Party_Accounting_Profile__c>()
                : new Map<Id, Party_Accounting_Profile__c>([
                    SELECT Id, Company__c
                    FROM Party_Accounting_Profile__c
                    WHERE Id IN :profileIds
                ]);

        Map<Id, Accounting_Event__c> events =
            eventIds.isEmpty()
                ? new Map<Id, Accounting_Event__c>()
                : new Map<Id, Accounting_Event__c>([
                    SELECT Id, Company__c
                    FROM Accounting_Event__c
                    WHERE Id IN :eventIds
                ]);

        for (Accounting_Payment__c recordValue : records) {
            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Bank_Account__c,
                relatedCompanyId(banks, recordValue.Bank_Account__c),
                'Bank Account'
            );

            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Party_Profile__c,
                relatedCompanyId(profiles, recordValue.Party_Profile__c),
                'Party Accounting Profile'
            );

            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Accounting_Event__c,
                relatedCompanyId(events, recordValue.Accounting_Event__c),
                'Accounting Event'
            );
        }
    }

    public static void validateEvents(
        List<Accounting_Event__c> records
    ) {
        Set<Id> journalIds = new Set<Id>();
        Set<Id> eventIds = new Set<Id>();

        for (Accounting_Event__c recordValue : records) {
            if (recordValue.Journal_Entry__c != null) {
                journalIds.add(recordValue.Journal_Entry__c);
            }
            if (recordValue.Reversal_Event__c != null) {
                eventIds.add(recordValue.Reversal_Event__c);
            }
        }

        Map<Id, Journal_Entry__c> journals =
            journalIds.isEmpty()
                ? new Map<Id, Journal_Entry__c>()
                : new Map<Id, Journal_Entry__c>([
                    SELECT Id, Company__c
                    FROM Journal_Entry__c
                    WHERE Id IN :journalIds
                ]);

        Map<Id, Accounting_Event__c> relatedEvents =
            eventIds.isEmpty()
                ? new Map<Id, Accounting_Event__c>()
                : new Map<Id, Accounting_Event__c>([
                    SELECT Id, Company__c
                    FROM Accounting_Event__c
                    WHERE Id IN :eventIds
                ]);

        for (Accounting_Event__c recordValue : records) {
            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Journal_Entry__c,
                relatedCompanyId(journals, recordValue.Journal_Entry__c),
                'Journal Entry'
            );

            assertSameCompany(
                recordValue,
                recordValue.Company__c,
                recordValue.Reversal_Event__c,
                relatedCompanyId(relatedEvents, recordValue.Reversal_Event__c),
                'Reversal Event'
            );
        }
    }

    private static void assertSameCompany(
        SObject targetRecord,
        Id expectedCompanyId,
        Id relatedId,
        Id relatedCompanyId,
        String relationshipLabel
    ) {
        if (
            relatedId == null
            || expectedCompanyId == null
        ) {
            return;
        }

        // If the related record is missing, Salesforce's lookup integrity will
        // reject the invalid foreign key. This guard is concerned with company
        // mismatch when the related record exists.
        if (relatedCompanyId == null) {
            return;
        }

        if (relatedCompanyId != expectedCompanyId) {
            targetRecord.addError(
                ERROR_PREFIX
                + relationshipLabel
                + ' must belong to the same Accounting Company.'
            );
        }
    }

    private static Id relatedCompanyId(
        Map<Id, Accounting_Period__c> records,
        Id recordId
    ) {
        return recordId != null && records.containsKey(recordId)
            ? records.get(recordId).Company__c
            : null;
    }

    private static Id relatedCompanyId(
        Map<Id, Accounting_Event__c> records,
        Id recordId
    ) {
        return recordId != null && records.containsKey(recordId)
            ? records.get(recordId).Company__c
            : null;
    }

    private static Id relatedCompanyId(
        Map<Id, Journal_Entry__c> records,
        Id recordId
    ) {
        return recordId != null && records.containsKey(recordId)
            ? records.get(recordId).Company__c
            : null;
    }

    private static Id relatedCompanyId(
        Map<Id, GL_Account__c> records,
        Id recordId
    ) {
        return recordId != null && records.containsKey(recordId)
            ? records.get(recordId).Company__c
            : null;
    }

    private static Id relatedCompanyId(
        Map<Id, Department__c> records,
        Id recordId
    ) {
        return recordId != null && records.containsKey(recordId)
            ? records.get(recordId).Company__c
            : null;
    }

    private static Id relatedCompanyId(
        Map<Id, Cost_Center__c> records,
        Id recordId
    ) {
        return recordId != null && records.containsKey(recordId)
            ? records.get(recordId).Company__c
            : null;
    }

    private static Id relatedCompanyId(
        Map<Id, Project__c> records,
        Id recordId
    ) {
        return recordId != null && records.containsKey(recordId)
            ? records.get(recordId).Company__c
            : null;
    }

    private static Id relatedCompanyId(
        Map<Id, Bank_Account__c> records,
        Id recordId
    ) {
        return recordId != null && records.containsKey(recordId)
            ? records.get(recordId).Company__c
            : null;
    }

    private static Id relatedCompanyId(
        Map<Id, Party_Accounting_Profile__c> records,
        Id recordId
    ) {
        return recordId != null && records.containsKey(recordId)
            ? records.get(recordId).Company__c
            : null;
    }

    private static Id relatedCompanyId(
        Map<Id, Invoice__c> records,
        Id recordId
    ) {
        return recordId != null && records.containsKey(recordId)
            ? records.get(recordId).Company__c
            : null;
    }


}
