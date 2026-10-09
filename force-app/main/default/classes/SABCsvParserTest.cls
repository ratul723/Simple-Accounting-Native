@IsTest
private class SABCsvParserTest {
    @IsTest
    static void parsesQuotesEscapesEmbeddedSeparatorsAndLineEndings() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<List<String>> rows = SABCsvParser.parse('code,name,note\r\n1100,"Bank, main","He said ""hi"""\n\n4000,Sales,"two\nlines"\n,,\n6000,Rent,');
            System.assertEquals(4, rows.size(), 'Blank lines and empty rows are skipped.');
            System.assertEquals(new List<String>{'code', 'name', 'note'}, rows[0], 'Header.');
            System.assertEquals('Bank, main', rows[1][1], 'Quoted comma.');
            System.assertEquals('He said "hi"', rows[1][2], 'Escaped quotes.');
            System.assertEquals('two\nlines', rows[2][2], 'Line break inside quotes.');
            System.assertEquals(new List<String>{'6000', 'Rent', ''}, rows[3], 'Trailing empty field.');
            System.assertEquals(0, SABCsvParser.parse('').size(), 'Empty input.');
            String failure;
            try {
                SABCsvParser.parse('a,"open');
            } catch (SABCsvParser.CsvException ex) {
                failure = ex.getMessage();
            }
            System.assert(failure != null && failure.contains('inside a quoted field'), 'Unterminated quote: ' + failure);
        }
    }
}
