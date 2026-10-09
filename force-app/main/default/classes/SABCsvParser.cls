/**
 * G20: RFC 4180 CSV parser. Handles quoted fields, escaped quotes (""), commas and line breaks inside quotes, and
 * CRLF or LF line endings. Blank lines are skipped. Pure calculation, no SOQL or DML.
 */
public with sharing class SABCsvParser {
    public class CsvException extends Exception {}

    public static List<List<String>> parse(String text) {
        List<List<String>> rows = new List<List<String>>();
        if (String.isBlank(text)) {
            return rows;
        }
        List<String> row = new List<String>();
        String field = '';
        Boolean quoted = false;
        Boolean fieldStarted = false;
        Integer i = 0;
        Integer n = text.length();
        while (i < n) {
            String c = text.substring(i, i + 1);
            if (quoted) {
                if (c == '"') {
                    if (i + 1 < n && text.substring(i + 1, i + 2) == '"') {
                        field += '"';
                        i++;
                    } else {
                        quoted = false;
                    }
                } else {
                    field += c;
                }
            } else if (c == '"' && !fieldStarted) {
                quoted = true;
                fieldStarted = true;
            } else if (c == ',') {
                row.add(field);
                field = '';
                fieldStarted = false;
            } else if (c == '\n' || c == '\r') {
                if (c == '\r' && i + 1 < n && text.substring(i + 1, i + 2) == '\n') {
                    i++;
                }
                row.add(field);
                addRow(rows, row);
                row = new List<String>();
                field = '';
                fieldStarted = false;
            } else {
                field += c;
                fieldStarted = true;
            }
            i++;
        }
        if (quoted) {
            throw new CsvException('The file ends inside a quoted field.');
        }
        if (fieldStarted || !row.isEmpty() || field != '') {
            row.add(field);
            addRow(rows, row);
        }
        return rows;
    }

    private static void addRow(List<List<String>> rows, List<String> row) {
        Boolean blank = true;
        for (String value : row) {
            if (String.isNotBlank(value)) {
                blank = false;
                break;
            }
        }
        if (!blank) {
            rows.add(row);
        }
    }
}
