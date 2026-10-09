/**
 * G22A: Finance home controller for c/sabFinanceHome. Thin wrapper over SABFinanceHomeService;
 * converts policy and service failures into AuraHandledException messages.
 */
public with sharing class SABFinanceHomeController {

    @AuraEnabled
    public static SABFinanceHomeService.HomeData getHome(Id companyId) {
        try {
            return SABFinanceHomeService.getHome(companyId);
        } catch (SABFinanceHomeReadPolicy.FinanceHomeAccessException ex) {
            throw auraError(ex.getMessage());
        } catch (QueryException ex) {
            throw auraError('Finance home could not be loaded: ' + ex.getMessage());
        }
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
